-- =========================================================================
-- El lote dice a quien se fue
--
-- EL PROBLEMA
-- -----------
-- La 223 dejo el contador del lote andando: FEFO consume del que vence antes
-- y devuelve al mismo lote cuando la venta se cae. Lo que NO dejo -- y lo dijo
-- en su propio encabezado, a proposito -- es la trazabilidad lote -> cliente:
-- "eso obligaria a guardar el lote en cada pedido_items y a tocar
-- crear_pedido_completo, que es la funcion mas parcheada del repo".
--
-- El agujero se ve el dia que hay que retirar mercaderia. stock_historico
-- (mig 240) guarda referencia_tipo/referencia_id a nivel PEDIDO, no a nivel
-- lote ni a nivel linea, asi que del ledger sale "salieron 6 unidades de este
-- producto por el pedido 1234" y nunca "tres de esas seis eran del lote que
-- vence el 12 de octubre". Con un solo lote sospechoso hay que llamar a todos
-- los clientes que compraron ese producto en el periodo, que es exactamente lo
-- que un sistema de lotes existe para evitar.
--
-- EL MODELO: UNA FILA POR (LINEA, LOTE), Y ES ESTADO, NO ASIENTO
-- --------------------------------------------------------------
-- Una linea de pedido puede comer de dos lotes si el primero no alcanza: la
-- relacion es 1:N y por eso es una tabla y no una columna en pedido_items.
--
-- pedido_item_lotes NO es un libro de asientos inmutable: es el estado actual
-- de que lote quedo afectado a que linea VIVA. Si la venta se cae -- se cancela
-- el pedido, se baja la cantidad, se hace una salvedad -- las unidades vuelven
-- al lote y la fila se descuenta o se borra, porque el cliente ya no las tiene
-- y no hay a quien llamar. Esa es la pregunta que la tabla contesta: "quien se
-- llevo mercaderia de este lote y todavia la tiene".
--
-- COMO SE ENTERA DE LA LINEA: UN GUC MAS
-- ---------------------------------------
-- El consumo no lo hacen las RPCs: lo hace el trigger trg_lotes_sincronizar
-- (223) colgado del UPDATE de productos.stock, que llama a
-- _consumir_lotes_fefo / _restaurar_lotes_fefo. El trigger ve producto,
-- sucursal y delta; de la linea no sabe nada.
--
-- La via ya existe y es la misma que usa el ledger desde la 038: un GUC de
-- transaccion que el caller setea antes del UPDATE. Se suma
-- `app.stock_pedido_item_id` a los cuatro `app.stock_*` que ya viajan. Los
-- cuatro viejos NO cambian -- el ledger sigue apuntando al pedido, que es su
-- granularidad correcta --; el nuevo es solo para esta tabla.
--
-- La restitucion tiene ADEMAS un camino sin GUC de linea. Cuando el que
-- devuelve stock etiqueto `app.stock_ref_tipo = 'pedido'` pero no dijo que
-- linea -- que es lo que hace hoy cancelar_pedido_con_stock desde la 229 --,
-- se descuenta de las filas de ESE pedido y de ESE producto. Es una
-- aproximacion solo en el 3,8% de los pedidos que repiten producto en dos
-- lineas (223 de 5861 en prod al 2026-09-15), y aun ahi el total por lote
-- queda bien: lo unico que puede quedar corrido es de cual de las dos lineas
-- se descuento. La alternativa era parchear una cuarta funcion caliente para
-- que la cancelacion no dejara filas fantasma, que es peor negocio.
--
-- LO QUE ESTA MIGRACION NO HACE, A PROPOSITO
-- -------------------------------------------
-- Solo crear_pedido_completo setea el GUC de linea. Faltan
-- crear_pedido_completo_bot y actualizar_pedido_items, que van en la migracion
-- siguiente: la del bot es el mismo parche por linea, y la de
-- actualizar_pedido_items no es un parche sino una reescritura -- hoy hace UN
-- UPDATE agregado por producto, asi que dos lineas del mismo producto se
-- funden en un solo statement y no hay forma de atribuir 1:1 sin volverlo un
-- bucle por linea.
--
-- Hasta que esas dos entren, la tabla tiene huecos por omision (un alta por el
-- bot o una suba de cantidad en una edicion consumen lote y no dejan fila). Un
-- hueco no ensucia nada -- nunca atribuye de mas --, pero alcanza para que la
-- tabla NO sirva todavia para un retiro. Por eso el front no se prende en esta
-- migracion ni en la que viene.
--
-- La lista blanca del trigger (223, corregida por la 229) no se toca: el
-- consumo por venta entra por la rama negativa, que no mira el origen.
-- =========================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 - El andamio de parcheo por ancla (mismo idiom que la 220 y la 229).
--     Se dropea al final: es andamio, no API.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public._mig256_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
)
RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);

  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano.',
      v_veces, p_funcion;
  END IF;

  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

CREATE OR REPLACE FUNCTION public._mig256_fn(p_nombre text)
RETURNS regprocedure
LANGUAGE sql
AS $fn$
  SELECT p.oid::regprocedure FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = p_nombre;
$fn$;

-- ---------------------------------------------------------------------------
-- 1 - La tabla
-- ---------------------------------------------------------------------------

-- Destino de la FK compuesta. producto_lotes nacio en la 223 sin este UNIQUE
-- porque nadie la referenciaba todavia; es el mismo paso que la 223 tuvo que
-- dar sobre productos. Nombre de la convencion 187:
-- <padre>_<columna>_<tenant_sin_id>_uk.
DO $mig$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
     WHERE conname = 'producto_lotes_id_sucursal_uk'
       AND conrelid = 'public.producto_lotes'::regclass
  ) THEN
    ALTER TABLE public.producto_lotes
      ADD CONSTRAINT producto_lotes_id_sucursal_uk UNIQUE (id, sucursal_id);
  END IF;
END
$mig$;

CREATE TABLE IF NOT EXISTS public.pedido_item_lotes (
  id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  pedido_item_id bigint  NOT NULL,
  lote_id        bigint  NOT NULL,
  cantidad       integer NOT NULL CHECK (cantidad > 0),
  sucursal_id    bigint  NOT NULL REFERENCES public.sucursales(id),
  created_at     timestamptz NOT NULL DEFAULT now(),

  -- FKs COMPUESTAS y no simples, por lo mismo que la 223: una FK simple no
  -- mira la sucursal y check-sucursal-cruzada.mjs marca al dia siguiente
  -- cualquier par hija->padre que no la lleve.
  --
  -- CASCADE de los dos lados y es lo que se quiere: si se borra la linea
  -- (una edicion que la saca, eliminar_pedido_completo) no hay a quien
  -- atribuirle nada, y si se borra el lote (borrar_lotes_compra_cancelada,
  -- mig 224) tampoco hay lote del que hablar.
  CONSTRAINT pedido_item_lotes_item_fk
    FOREIGN KEY (pedido_item_id, sucursal_id)
    REFERENCES public.pedido_items(id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT pedido_item_lotes_lote_fk
    FOREIGN KEY (lote_id, sucursal_id)
    REFERENCES public.producto_lotes(id, sucursal_id) ON DELETE CASCADE,

  -- Una linea y un lote se cruzan en UNA fila, no en un asiento por
  -- movimiento: la tabla es estado. Si la misma linea vuelve a comer del mismo
  -- lote -- baja y despues sube la cantidad -- suma sobre la fila que ya esta.
  CONSTRAINT pedido_item_lotes_unico UNIQUE (pedido_item_id, lote_id)
);

COMMENT ON TABLE public.pedido_item_lotes IS
  'Que lote se le fue a que linea de pedido. Estado, no asiento: si la venta '
  'se cae la fila se descuenta o se borra, porque el cliente ya no tiene esa '
  'mercaderia. La escribe _consumir_lotes_fefo cuando el caller declaro '
  'app.stock_pedido_item_id. mig 256.';

COMMENT ON COLUMN public.pedido_item_lotes.cantidad IS
  'Unidades de ese lote que estan hoy en poder del cliente por esta linea. '
  'Nunca 0: al llegar a 0 la fila se borra.';

-- "Quien se llevo este lote" (el panel de vencimientos) entra por aca.
-- El otro sentido -- "de que lotes salio esta linea" -- ya lo cubre el UNIQUE.
CREATE INDEX IF NOT EXISTS idx_pedido_item_lotes_lote
  ON public.pedido_item_lotes (lote_id);

-- ---------------------------------------------------------------------------
-- 2 - RLS: la misma policy de lectura que producto_lotes (223 seccion 2) y
--     nada mas.
--
-- Toda la escritura entra por SECURITY DEFINER, asi que el default-deny de RLS
-- alcanza. El REVOKE de abajo es cinturon y tiradores: el default privilege del
-- baseline (mig 186) le da INSERT/UPDATE/DELETE a cualquier logueado sobre toda
-- tabla nueva de public, y hoy lo unico que lo frena es que no exista policy de
-- escritura. Una policy de escritura agregada de apuro manana abriria la tabla
-- entera sin que nada avise; sin el GRANT, no.
-- ---------------------------------------------------------------------------

ALTER TABLE public.pedido_item_lotes ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_pedido_item_lotes_select ON public.pedido_item_lotes;
CREATE POLICY mt_pedido_item_lotes_select ON public.pedido_item_lotes
  FOR SELECT TO authenticated
  USING (
    (public.es_encargado_o_admin() OR EXISTS (
      SELECT 1 FROM public.perfiles
       WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
    AND sucursal_id = public.current_sucursal_id()
  );

REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.pedido_item_lotes
  FROM PUBLIC, anon, authenticated;
REVOKE SELECT ON public.pedido_item_lotes FROM PUBLIC, anon;
GRANT SELECT ON public.pedido_item_lotes TO authenticated;

-- ---------------------------------------------------------------------------
-- 3 - _consumir_lotes_fefo: deja la huella cuando el caller dijo de que linea
--     es la bajada.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig256_ancla(
    public._mig256_fn('_consumir_lotes_fefo'),
    E'  v_toma      integer;\n  r           record;\nBEGIN\n',
    E'  v_toma      integer;\n'
    || E'  r           record;\n'
    || E'  -- mig 256: de que linea de pedido es esta bajada. Lo setea el caller\n'
    || E'  -- antes del UPDATE de stock; vacio o ausente = no es una venta con\n'
    || E'  -- linea conocida (merma, transferencia, control de stock) y no se\n'
    || E'  -- escribe huella. El regex evita que un GUC basura reviente el cast.\n'
    || E'  v_item_id   bigint := CASE\n'
    || E'    WHEN COALESCE(current_setting(''app.stock_pedido_item_id'', true), '''') ~ ''^[0-9]+$''\n'
    || E'    THEN current_setting(''app.stock_pedido_item_id'', true)::bigint END;\n'
    || E'BEGIN\n'
  );

  PERFORM public._mig256_ancla(
    public._mig256_fn('_consumir_lotes_fefo'),
    E'    v_toma := LEAST(v_pendiente, r.cantidad_restante);\n'
    || E'    UPDATE public.producto_lotes\n'
    || E'       SET cantidad_restante = cantidad_restante - v_toma\n'
    || E'     WHERE id = r.id;\n'
    || E'    v_pendiente := v_pendiente - v_toma;\n',
    E'    v_toma := LEAST(v_pendiente, r.cantidad_restante);\n'
    || E'    UPDATE public.producto_lotes\n'
    || E'       SET cantidad_restante = cantidad_restante - v_toma\n'
    || E'     WHERE id = r.id;\n'
    || E'\n'
    || E'    -- mig 256: la huella lote -> linea. El SELECT sobre pedido_items es el\n'
    || E'    -- guard, no un adorno: si el GUC quedo colgado de otra linea o de otro\n'
    || E'    -- producto no inserta nada, en vez de inventar una atribucion. Vale\n'
    || E'    -- mas un hueco que una fila que manda a llamar al cliente equivocado.\n'
    || E'    IF v_item_id IS NOT NULL THEN\n'
    || E'      INSERT INTO public.pedido_item_lotes (pedido_item_id, lote_id, cantidad, sucursal_id)\n'
    || E'      SELECT pi.id, r.id, v_toma, pi.sucursal_id\n'
    || E'        FROM public.pedido_items pi\n'
    || E'       WHERE pi.id = v_item_id\n'
    || E'         AND pi.producto_id = p_producto_id\n'
    || E'         AND pi.sucursal_id = p_sucursal_id\n'
    || E'      ON CONFLICT (pedido_item_id, lote_id)\n'
    || E'        DO UPDATE SET cantidad = pedido_item_lotes.cantidad + EXCLUDED.cantidad;\n'
    || E'    END IF;\n'
    || E'\n'
    || E'    v_pendiente := v_pendiente - v_toma;\n'
  );
END;
$patch$;

COMMENT ON FUNCTION public._consumir_lotes_fefo(bigint, bigint, integer) IS
  'Descuenta N unidades de los lotes del producto, el que vence antes primero. '
  'Devuelve cuanto pudo descontar. Si el caller declaro '
  'app.stock_pedido_item_id, deja la huella en pedido_item_lotes. mig 223, 256.';

-- ---------------------------------------------------------------------------
-- 4 - _restaurar_lotes_fefo: lo que vuelve al lote sale de la huella.
--
--     Se descuenta del MISMO lote que se acaba de reponer, adentro del mismo
--     paso del bucle: asi no hay que adivinar despues en que orden se habia
--     repartido. Dos alcances, en este orden:
--       * si el caller dijo la linea (app.stock_pedido_item_id), esa linea;
--       * si no, pero etiqueto el pedido (app.stock_ref_tipo = 'pedido'), las
--         lineas de ese pedido para ESE producto. Es el caso de
--         cancelar_pedido_con_stock y de las dos restituciones de
--         actualizar_pedido_items, que etiquetan el pedido desde la 229.
--     Sin ninguno de los dos no se toca nada: una merma o una transferencia
--     tambien devuelven al lote y no tienen cliente del otro lado.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  PERFORM public._mig256_ancla(
    public._mig256_fn('_restaurar_lotes_fefo'),
    E'  v_pone      integer;\n  r           record;\nBEGIN\n',
    E'  v_pone      integer;\n'
    || E'  r           record;\n'
    || E'  -- mig 256: a quien se le descuenta la huella. Ver el encabezado de la\n'
    || E'  -- migracion: la linea si el caller la dijo, y si no el pedido.\n'
    || E'  v_item_id   bigint := CASE\n'
    || E'    WHEN COALESCE(current_setting(''app.stock_pedido_item_id'', true), '''') ~ ''^[0-9]+$''\n'
    || E'    THEN current_setting(''app.stock_pedido_item_id'', true)::bigint END;\n'
    || E'  v_pedido_id bigint := CASE\n'
    || E'    WHEN COALESCE(current_setting(''app.stock_ref_tipo'', true), '''') = ''pedido''\n'
    || E'     AND COALESCE(current_setting(''app.stock_ref_id'', true), '''') ~ ''^[0-9]+$''\n'
    || E'    THEN current_setting(''app.stock_ref_id'', true)::bigint END;\n'
    || E'  v_devolver  integer;\n'
    || E'  v_baja      integer;\n'
    || E'  h           record;\n'
    || E'BEGIN\n'
  );

  PERFORM public._mig256_ancla(
    public._mig256_fn('_restaurar_lotes_fefo'),
    E'    v_pone := LEAST(v_pendiente, r.hueco);\n'
    || E'    UPDATE public.producto_lotes\n'
    || E'       SET cantidad_restante = cantidad_restante + v_pone\n'
    || E'     WHERE id = r.id;\n'
    || E'    v_pendiente := v_pendiente - v_pone;\n',
    E'    v_pone := LEAST(v_pendiente, r.hueco);\n'
    || E'    UPDATE public.producto_lotes\n'
    || E'       SET cantidad_restante = cantidad_restante + v_pone\n'
    || E'     WHERE id = r.id;\n'
    || E'\n'
    || E'    -- mig 256: lo que volvio al lote ya no lo tiene el cliente.\n'
    || E'    IF v_item_id IS NOT NULL OR v_pedido_id IS NOT NULL THEN\n'
    || E'      v_devolver := v_pone;\n'
    || E'      FOR h IN\n'
    || E'        SELECT pil.id, pil.cantidad\n'
    || E'          FROM public.pedido_item_lotes pil\n'
    || E'          JOIN public.pedido_items pi\n'
    || E'            ON pi.id = pil.pedido_item_id AND pi.sucursal_id = pil.sucursal_id\n'
    || E'         WHERE pil.lote_id = r.id\n'
    || E'           AND CASE WHEN v_item_id IS NOT NULL\n'
    || E'                    THEN pil.pedido_item_id = v_item_id\n'
    || E'                    ELSE pi.pedido_id = v_pedido_id AND pi.producto_id = p_producto_id\n'
    || E'               END\n'
    || E'         ORDER BY pil.id\n'
    || E'         FOR UPDATE OF pil\n'
    || E'      LOOP\n'
    || E'        EXIT WHEN v_devolver <= 0;\n'
    || E'        v_baja := LEAST(v_devolver, h.cantidad);\n'
    || E'        IF v_baja >= h.cantidad THEN\n'
    || E'          DELETE FROM public.pedido_item_lotes WHERE id = h.id;\n'
    || E'        ELSE\n'
    || E'          UPDATE public.pedido_item_lotes SET cantidad = cantidad - v_baja WHERE id = h.id;\n'
    || E'        END IF;\n'
    || E'        v_devolver := v_devolver - v_baja;\n'
    || E'      END LOOP;\n'
    || E'    END IF;\n'
    || E'\n'
    || E'    v_pendiente := v_pendiente - v_pone;\n'
  );
END;
$patch$;

COMMENT ON FUNCTION public._restaurar_lotes_fefo(bigint, bigint, integer) IS
  'Devuelve N unidades a los lotes del producto, el que vence antes primero. '
  'Inversa de _consumir_lotes_fefo, tambien para la huella de '
  'pedido_item_lotes. mig 223, 256.';

-- ---------------------------------------------------------------------------
-- 5 - crear_pedido_completo: la linea se declara y se apaga enseguida.
--
--     El GUC se prende justo antes de la bajada de ESTA linea y se apaga
--     apenas termina, antes del bloque de auto-ajuste de promo, que tambien
--     baja stock: ese es una merma del producto contenedor, no mercaderia que
--     se llevo el cliente. set_config es por transaccion, no por statement
--     (la leccion de la 229 seccion 3): lo que no se apaga, sigue prendido.
-- ---------------------------------------------------------------------------

DO $patch$
BEGIN
  -- 5.a - la variable
  PERFORM public._mig256_ancla(
    public._mig256_fn('crear_pedido_completo'),
    E'  v_merma_id BIGINT;\n',
    E'  v_merma_id BIGINT;\n  v_item_id BIGINT;\n'
  );

  -- 5.b - el id de la linea recien insertada
  PERFORM public._mig256_ancla(
    public._mig256_fn('crear_pedido_completo'),
    E'      v_sucursal, v_descripcion_regalo, v_stock_al_crear, v_costo_al_crear\n    );\n',
    E'      v_sucursal, v_descripcion_regalo, v_stock_al_crear, v_costo_al_crear\n'
    || E'    ) RETURNING id INTO v_item_id;\n'
  );

  -- 5.c - el GUC alrededor de la bajada de stock de la linea
  PERFORM public._mig256_ancla(
    public._mig256_fn('crear_pedido_completo'),
    E'    IF NOT v_es_bonificacion THEN\n'
    || E'      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;\n'
    || E'    ELSIF v_promocion_id IS NOT NULL THEN\n'
    || E'      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;\n'
    || E'      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN\n'
    || E'        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;\n'
    || E'      END IF;\n'
    || E'    END IF;\n',
    E'    -- mig 256: de aca sale la huella lote -> linea (pedido_item_lotes). Se\n'
    || E'    -- apaga apenas termina la bajada a proposito: el auto-ajuste de promo\n'
    || E'    -- que viene despues tambien baja stock y es una merma del contenedor,\n'
    || E'    -- no mercaderia que se llevo el cliente.\n'
    || E'    PERFORM set_config(''app.stock_pedido_item_id'', v_item_id::TEXT, true);\n'
    || E'\n'
    || E'    IF NOT v_es_bonificacion THEN\n'
    || E'      UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;\n'
    || E'    ELSIF v_promocion_id IS NOT NULL THEN\n'
    || E'      SELECT regalo_mueve_stock INTO v_regalo_mueve_stock FROM promociones WHERE id = v_promocion_id AND sucursal_id = v_sucursal;\n'
    || E'      IF COALESCE(v_regalo_mueve_stock, FALSE) THEN\n'
    || E'        UPDATE productos SET stock = stock - v_cantidad WHERE id = v_producto_id AND sucursal_id = v_sucursal;\n'
    || E'      END IF;\n'
    || E'    END IF;\n'
    || E'\n'
    || E'    PERFORM set_config(''app.stock_pedido_item_id'', '''', true);\n'
  );
END;
$patch$;

-- ---------------------------------------------------------------------------
-- 6 - Verificacion estatica: los tres cuerpos vivos quedaron parcheados y la
--     tabla no quedo escribible.
-- ---------------------------------------------------------------------------

DO $verif$
DECLARE
  v_fallas text := '';
BEGIN
  IF pg_get_functiondef(public._mig256_fn('_consumir_lotes_fefo'))
     NOT LIKE '%INSERT INTO public.pedido_item_lotes%' THEN
    v_fallas := v_fallas || ' [_consumir_lotes_fefo no escribe la huella]';
  END IF;
  IF pg_get_functiondef(public._mig256_fn('_restaurar_lotes_fefo'))
     NOT LIKE '%DELETE FROM public.pedido_item_lotes%' THEN
    v_fallas := v_fallas || ' [_restaurar_lotes_fefo no descuenta la huella]';
  END IF;
  IF pg_get_functiondef(public._mig256_fn('crear_pedido_completo'))
     NOT LIKE '%app.stock_pedido_item_id%' THEN
    v_fallas := v_fallas || ' [crear_pedido_completo no declara la linea]';
  END IF;
  IF pg_get_functiondef(public._mig256_fn('crear_pedido_completo'))
     NOT LIKE '%RETURNING id INTO v_item_id%' THEN
    v_fallas := v_fallas || ' [crear_pedido_completo no captura el id de la linea]';
  END IF;

  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'pedido_item_lotes'
       AND grantee IN ('anon', 'authenticated', 'PUBLIC')
       AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')
  ) THEN
    v_fallas := v_fallas || ' [pedido_item_lotes quedo escribible por anon/authenticated]';
  END IF;
  IF EXISTS (
    SELECT 1 FROM information_schema.role_table_grants
     WHERE table_schema = 'public' AND table_name = 'pedido_item_lotes'
       AND grantee IN ('anon', 'PUBLIC') AND privilege_type = 'SELECT'
  ) THEN
    v_fallas := v_fallas || ' [pedido_item_lotes quedo legible por anon]';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_policies
     WHERE schemaname = 'public' AND tablename = 'pedido_item_lotes' AND cmd <> 'SELECT'
  ) THEN
    v_fallas := v_fallas || ' [pedido_item_lotes tiene policy de escritura]';
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig256 - la verificacion estatica encontro:%', v_fallas;
  END IF;
END
$verif$;

-- ---------------------------------------------------------------------------
-- 7 - Ensayo funcional, sobre el cuerpo vivo y con ROLLBACK (molde de la 240).
--     Un producto con dos lotes (3 y 5) y un pedido de 6: la linea tiene que
--     quedar partida 3 y 3, y la cancelacion tiene que dejar la huella en cero
--     y los dos lotes enteros otra vez.
-- ---------------------------------------------------------------------------

DO $ensayo$
DECLARE
  v_uid            uuid;
  v_suc            bigint;
  v_fallas         text := '';
  v_filas          int;
  v_reparto        text;
  v_restantes      text;
  v_item_ok        boolean;
  v_filas_post     int;
  v_restantes_post text;
  v_err_cancel     text;
BEGIN
  SELECT p.id, us.sucursal_id INTO v_uid, v_suc
    FROM perfiles p
    JOIN usuario_sucursales us ON us.usuario_id = p.id AND us.es_default
   WHERE p.rol = 'admin'
   ORDER BY p.id
   LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'mig256: no hay ningun admin con sucursal por defecto; el ensayo no puede correr.';
  END IF;

  BEGIN
    PERFORM set_config('request.jwt.claims', json_build_object('sub', v_uid)::text, true);
    PERFORM set_config('request.headers', json_build_object('x-sucursal-id', v_suc::text)::text, true);

    DECLARE
      v_prod bigint; v_l1 bigint; v_l2 bigint;
      v_cli bigint; v_ped bigint; v_res jsonb;
    BEGIN
      INSERT INTO productos (nombre, precio, sucursal_id, stock)
        VALUES ('ZZZ mig256', 100000, v_suc, 8) RETURNING id INTO v_prod;

      -- 3 + 5 = 8 = stock: la bolsa "sin vencimiento" arranca en cero, asi que
      -- la venta pega derecho contra los lotes.
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento,
                                  cantidad, cantidad_restante, origen)
        VALUES (v_prod, v_suc, CURRENT_DATE + 30, 3, 3, 'manual') RETURNING id INTO v_l1;
      INSERT INTO producto_lotes (producto_id, sucursal_id, fecha_vencimiento,
                                  cantidad, cantidad_restante, origen)
        VALUES (v_prod, v_suc, CURRENT_DATE + 60, 5, 5, 'manual') RETURNING id INTO v_l2;

      INSERT INTO clientes (razon_social, nombre_fantasia, direccion, sucursal_id)
        VALUES ('ZZZ mig256', 'ZZZ mig256', 'ZZZ', v_suc) RETURNING id INTO v_cli;

      v_res := crear_pedido_completo(
                 v_cli, 600000, v_uid,
                 jsonb_build_array(jsonb_build_object(
                   'producto_id', v_prod, 'cantidad', 6, 'precio_unitario', 100000)),
                 'ensayo mig256');
      IF NOT (v_res->>'success')::boolean THEN
        RAISE EXCEPTION 'el alta de pedido fallo: %', v_res->>'errores';
      END IF;
      v_ped := (v_res->>'pedido_id')::bigint;

      SELECT count(*),
             string_agg(pil.cantidad::text, '+' ORDER BY pl.fecha_vencimiento),
             bool_and(pi.pedido_id = v_ped AND pil.sucursal_id = v_suc)
        INTO v_filas, v_reparto, v_item_ok
        FROM pedido_item_lotes pil
        JOIN producto_lotes pl ON pl.id = pil.lote_id
        JOIN pedido_items pi   ON pi.id = pil.pedido_item_id
       WHERE pl.producto_id = v_prod;

      SELECT string_agg(cantidad_restante::text, '+' ORDER BY fecha_vencimiento)
        INTO v_restantes FROM producto_lotes WHERE producto_id = v_prod;

      v_res := cancelar_pedido_con_stock(v_ped, 'ensayo mig256', NULL, 'prueba');
      IF NOT (v_res->>'success')::boolean THEN
        v_err_cancel := v_res->>'error';
      END IF;

      SELECT count(*) INTO v_filas_post
        FROM pedido_item_lotes pil
        JOIN producto_lotes pl ON pl.id = pil.lote_id
       WHERE pl.producto_id = v_prod;

      SELECT string_agg(cantidad_restante::text, '+' ORDER BY fecha_vencimiento)
        INTO v_restantes_post FROM producto_lotes WHERE producto_id = v_prod;
    END;

    RAISE EXCEPTION 'mig256_rollback_del_ensayo';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'mig256_rollback_del_ensayo' THEN
      RAISE EXCEPTION 'mig256 - el ensayo funcional exploto: %', SQLERRM;
    END IF;
  END;

  IF v_err_cancel IS NOT NULL THEN
    v_fallas := v_fallas || format(' [la cancelacion fallo: %s]', v_err_cancel);
  END IF;
  IF v_filas <> 2 THEN
    v_fallas := v_fallas || format(' [la linea dejo %s filas en vez de 2]', v_filas);
  END IF;
  IF v_reparto IS DISTINCT FROM '3+3' THEN
    v_fallas := v_fallas || format(' [el reparto por lote fue %s en vez de 3+3]', v_reparto);
  END IF;
  IF NOT COALESCE(v_item_ok, false) THEN
    v_fallas := v_fallas || ' [las filas no cuelgan del pedido o de la sucursal que corresponde]';
  END IF;
  IF v_restantes IS DISTINCT FROM '0+2' THEN
    v_fallas := v_fallas || format(' [los lotes quedaron en %s en vez de 0+2]', v_restantes);
  END IF;
  IF v_filas_post <> 0 THEN
    v_fallas := v_fallas || format(' [la cancelacion dejo %s filas vivas]', v_filas_post);
  END IF;
  IF v_restantes_post IS DISTINCT FROM '3+5' THEN
    v_fallas := v_fallas || format(' [los lotes no volvieron enteros: %s en vez de 3+5]', v_restantes_post);
  END IF;

  IF v_fallas <> '' THEN
    RAISE EXCEPTION 'mig256 - el ensayo funcional encontro:%', v_fallas;
  END IF;

  RAISE NOTICE 'mig256 - ensayo OK: reparto=% lotes=% / post-cancelacion filas=% lotes=%',
    v_reparto, v_restantes, v_filas_post, v_restantes_post;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 8 - Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._mig256_ancla(regprocedure, text, text);
DROP FUNCTION public._mig256_fn(text);

COMMIT;
