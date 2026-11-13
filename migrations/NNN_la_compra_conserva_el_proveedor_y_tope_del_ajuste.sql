-- =========================================================================
-- NNN · LA COMPRA CONSERVA EL NOMBRE DEL PROVEEDOR, Y LA NC DE AJUSTE
--       CUADRA Y NO PASA LO QUE LE QUEDA A LA COMPRA
--       (reauditoría del núcleo del 12/11: CMP-4 y CMP-2 de #1557;
--        tarjeta 2 de #1565)
--
-- Crea una función de trigger sobre `compras`, rellena el nombre de las
-- compras que sólo tienen el id, reemplaza el cuerpo entero de
-- `eliminar_proveedor` y parcha por ancla la rama `ajuste` de
-- `registrar_nota_credito`, con premisa de md5 sobre el cuerpo vivo leído el
-- 12/11 y poscondición de md5 y ACL.
-- Ensayo: scripts/test-proveedor-en-la-compra-y-nc-de-ajuste-1557.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · CMP-4 · ELIMINAR UN PROVEEDOR DEJABA SUS COMPRAS SIN PROVEEDOR
-- =========================================================================
-- El aviso de Proveedores prometía que «las compras asociadas conservarán el
-- nombre del proveedor», pero nadie lo guardaba: el modal de la compra manda
-- `p_proveedor_nombre = null` cuando hay un proveedor elegido, y la FK
-- `compras_proveedor_id_fkey` es `ON DELETE SET NULL (proveedor_id)`. Al
-- eliminar el proveedor, la compra quedaba sin id y sin nombre. En prod, 225
-- de las 231 compras vivas tenían el id y no el nombre, y una (la 4) ya lo
-- perdió así.
--
-- Decisión del dueño (12/11): la compra conserva el nombre y el proveedor se
-- puede eliminar.
--   · `compras_guarda_proveedor_nombre` (BEFORE INSERT OR UPDATE OF
--     proveedor_id, proveedor_nombre): con un proveedor, el nombre de la
--     compra es el del proveedor. Lo cumplen el alta, el clon de
--     `cambiar_proveedor_compra`, la edición y cualquier escritura futura, sin
--     tocar `registrar_compra_completa` (es de la tarjeta 3). Si la compra se
--     queda sin proveedor (el SET NULL de la FK) y no tenía nombre, toma el
--     de `proveedores_eliminados`.
--   · `eliminar_proveedor` copia el nombre vigente a sus compras antes del
--     DELETE (lo que mostraba la pantalla, aunque el proveedor se haya
--     renombrado después de la compra). Bloquea en el orden global, explícito
--     y no librado al orden en que disparan las acciones de las FKs: el
--     proveedor primero (como el alta de una compra, cuyo INSERT le toma KEY
--     SHARE antes de bloquear los productos), después sus compras y sus
--     productos, por id (compra → productos, como la edición de una compra).
--     Contra el alta de una compra suya, el que llega segundo espera al otro:
--     si es el alta, la FK la rechaza porque el proveedor ya no existe. Lo
--     mide la variante P2 del arnés (0 `40P01`, antes y después; antes, con
--     las compras sin nombre). Devuelve además cuántas compras, productos y
--     equivalencias toca.
--   · Lo que la FK sigue haciendo, y el aviso del front ahora dice: borra en
--     cascada las equivalencias de códigos y deja `productos.proveedor_id` en
--     NULL.
--   · El relleno: toda compra con id y sin nombre recibe el del proveedor.
--   · La compra que ya perdió el proveedor se repone desde `audit_logs` (el
--     UPDATE que le sacó el id) y `proveedores_eliminados` (el nombre). Es un
--     dato de prod y va con el OK del dueño.
--
-- =========================================================================
-- 2 · CMP-2 · LA NC DE AJUSTE NO TENÍA TOPE NI CUADRE
-- =========================================================================
-- La rama `ajuste` (sin mercadería) sólo pedía importes ≥ 0 y total > 0.
-- Sobre una compra de 1.210 entraban ajustes de 50.000 y 30.000, y el
-- gerencial los sumaba como `descuentos_proveedores` a todos los márgenes.
-- También entraba un ajuste de 100 + 21 con total 9.999.
--   · Cuadre: subtotal + IVA + II = total, al centavo.
--   · Tope: el total de la nota no pasa lo que le queda a la compra, su total
--     menos las notas de crédito que ya tiene (de devolución y de ajuste; las
--     notas no se anulan, todas están vigentes).
--   · Lo serializa el FOR UPDATE de las líneas de la compra que la RPC ya toma
--     antes de bifurcar (mig 236): dos notas sobre la misma compra se esperan,
--     y la segunda cuenta a la primera. En prod no hay compras sin líneas.
--   · Un NaN o un infinito no pasa: el cuadre lo da distinto y el tope lo ve
--     mayor que todo.
-- En prod hay una NC de ajuste, dentro del total de su compra (leído el 12/11).
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisa: los cuerpos vivos son los leídos el 12/11, y el trigger no existe
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.eliminar_proveedor(bigint)', 'cdbfba8b892a1aecf3ad5fc7e92815e1'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '545ef1c0cabf4e71d1b1096fde53b49a')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %): rehacer sobre la definición vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regprocedure('public.compras_guarda_proveedor_nombre()') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.compras'::regclass
                                           AND tgname = 'trg_compras_guarda_proveedor_nombre') THEN
    RAISE EXCEPTION 'mig NNN · compras_guarda_proveedor_nombre ya existe: revisar a mano';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1a · el trigger: con un proveedor, la compra guarda su nombre
-- ---------------------------------------------------------------------------
-- INVOKER: `compras` no tiene escritura REST (authenticated sólo la lee), así
-- que la escriben las RPCs DEFINER y el SET NULL de la FK, que corre como
-- dueño de la tabla. Es de trigger: sin EXECUTE para nadie de la app.
CREATE FUNCTION public.compras_guarda_proveedor_nombre()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_nombre TEXT;
BEGIN
  IF NEW.proveedor_id IS NOT NULL THEN
    SELECT p.nombre INTO v_nombre
      FROM public.proveedores p
     WHERE p.id = NEW.proveedor_id AND p.sucursal_id = NEW.sucursal_id;
    IF FOUND THEN
      NEW.proveedor_nombre := v_nombre;
    END IF;
  ELSIF TG_OP = 'UPDATE' AND OLD.proveedor_id IS NOT NULL AND NEW.proveedor_nombre IS NULL THEN
    -- Se quedó sin proveedor (el SET NULL de la FK al eliminarlo): conserva el
    -- nombre. `eliminar_proveedor` ya lo copió; esto cubre una compra que no
    -- lo tuviera y un DELETE que no pase por la RPC.
    NEW.proveedor_nombre := COALESCE(OLD.proveedor_nombre,
      (SELECT pe.nombre FROM public.proveedores_eliminados pe
        WHERE pe.proveedor_id = OLD.proveedor_id
        ORDER BY pe.id DESC LIMIT 1));
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.compras_guarda_proveedor_nombre() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_compras_guarda_proveedor_nombre
  BEFORE INSERT OR UPDATE OF proveedor_id, proveedor_nombre ON public.compras
  FOR EACH ROW EXECUTE FUNCTION public.compras_guarda_proveedor_nombre();

-- ---------------------------------------------------------------------------
-- 1b · el relleno: toda compra con id recibe el nombre de su proveedor
-- ---------------------------------------------------------------------------
UPDATE public.compras c
   SET proveedor_nombre = p.nombre
  FROM public.proveedores p
 WHERE p.id = c.proveedor_id
   AND p.sucursal_id = c.sucursal_id
   AND c.proveedor_nombre IS NULL;

-- ---------------------------------------------------------------------------
-- 1c · la compra que ya perdió el proveedor (con el OK del dueño)
-- ---------------------------------------------------------------------------
-- El UPDATE de `audit_logs` que le sacó el id dice cuál era; el nombre sale de
-- `proveedores_eliminados`. En prod es una: la 4 (cancelada), proveedor 3.
UPDATE public.compras c
   SET proveedor_nombre = x.nombre
  FROM (
    SELECT DISTINCT ON (a.registro_id) a.registro_id, pe.nombre
      FROM public.audit_logs a
      JOIN public.proveedores_eliminados pe
        ON pe.proveedor_id = (a.old_data->>'proveedor_id')::BIGINT
     WHERE a.tabla = 'compras'
       AND a.accion = 'UPDATE'
       AND a.old_data->>'proveedor_id' IS NOT NULL
       AND a.new_data->>'proveedor_id' IS NULL
     ORDER BY a.registro_id, a.created_at DESC, pe.id DESC
  ) x
 WHERE c.id::TEXT = x.registro_id
   AND c.proveedor_id IS NULL
   AND c.proveedor_nombre IS NULL;

-- ---------------------------------------------------------------------------
-- 1d · eliminar_proveedor copia el nombre y bloquea en el orden del alta
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.eliminar_proveedor(p_proveedor_id bigint)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal BIGINT := current_sucursal_id();
  v_proveedor RECORD;
  v_compras INTEGER;
  v_productos INTEGER;
  v_equivalencias INTEGER;
BEGIN
  -- #1009: el rol se chequea afuera del bloque con EXCEPTION, para que el
  -- rechazo llegue como error (42501) y no como {success:false}.
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Acceso denegado: sólo un admin puede eliminar proveedores'
      USING ERRCODE = '42501';
  END IF;

  BEGIN
    /* #1557 (CMP-4) · EL ORDEN GLOBAL, EXPLÍCITO. El alta de una compra le
       toma KEY SHARE al proveedor (la FK, en el INSERT) y después bloquea los
       productos por id; la edición, la compra y después los productos. Acá:
       el proveedor primero (FOR UPDATE espera al alta en vuelo, o la deja
       esperando a ella, y entonces la FK la rechaza), y después sus compras y
       sus productos, por id, antes del DELETE. Así el orden no queda librado
       al de las acciones de las FKs (SET NULL en compras y productos, CASCADE
       en las equivalencias), que lo decide el orden de sus triggers. */
    SELECT * INTO v_proveedor
      FROM proveedores
     WHERE id = p_proveedor_id
       AND sucursal_id = v_sucursal
       FOR UPDATE;

    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'Proveedor no encontrado');
    END IF;

    PERFORM 1 FROM compras
     WHERE proveedor_id = p_proveedor_id AND sucursal_id = v_sucursal
     ORDER BY id
       FOR UPDATE;
    GET DIAGNOSTICS v_compras = ROW_COUNT;

    PERFORM 1 FROM productos
     WHERE proveedor_id = p_proveedor_id AND sucursal_id = v_sucursal
     ORDER BY id
       FOR UPDATE;
    GET DIAGNOSTICS v_productos = ROW_COUNT;

    SELECT count(*)::INTEGER INTO v_equivalencias
      FROM producto_equivalencias_proveedor
     WHERE proveedor_id = p_proveedor_id AND sucursal_id = v_sucursal;

    -- Guardar registro en tabla de auditoría
    INSERT INTO proveedores_eliminados (
      proveedor_id, nombre, cuit, direccion, telefono, email,
      contacto, notas, activo, fecha_creacion, eliminado_por
    ) VALUES (
      v_proveedor.id,
      v_proveedor.nombre,
      v_proveedor.cuit,
      v_proveedor.direccion,
      v_proveedor.telefono,
      v_proveedor.email,
      v_proveedor.contacto,
      v_proveedor.notas,
      v_proveedor.activo,
      v_proveedor.created_at,
      auth.uid()
    );

    -- #1557 (CMP-4): las compras conservan el nombre. El vigente, que es el
    -- que mostraba la pantalla aunque el proveedor se haya renombrado después
    -- de la compra. El trigger de `compras` lo cuida también en el SET NULL.
    UPDATE compras
       SET proveedor_nombre = v_proveedor.nombre
     WHERE proveedor_id = p_proveedor_id
       AND sucursal_id = v_sucursal
       AND proveedor_nombre IS DISTINCT FROM v_proveedor.nombre;

    -- La FK deja `compras.proveedor_id` y `productos.proveedor_id` en NULL y
    -- borra en cascada las equivalencias del proveedor.
    DELETE FROM proveedores WHERE id = p_proveedor_id AND sucursal_id = v_sucursal;

    RETURN jsonb_build_object(
      'success', true,
      'nombre', v_proveedor.nombre,
      'compras', v_compras,
      'productos_sin_proveedor', v_productos,
      'equivalencias_borradas', v_equivalencias
    );
  EXCEPTION
    WHEN OTHERS THEN
      RETURN jsonb_build_object('success', false, 'error', SQLERRM);
  END;
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · registrar_nota_credito: el ajuste cuadra y tiene tope
-- ---------------------------------------------------------------------------
DO $parche_nc$
DECLARE
  v_def text := pg_get_functiondef(
    'public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)'::regprocedure);
  v_a1 text := $a$  v_aviso TEXT; v_avisos JSONB := '[]'::JSONB;  -- mig 483
$a$;
  v_r1 text := $r$  v_aviso TEXT; v_avisos JSONB := '[]'::JSONB;  -- mig 483
  v_resta NUMERIC;  -- #1557 (CMP-2)
$r$;
  v_a2 text := $a$    v_subtotal := p_subtotal;
    v_iva      := p_iva;
    v_ii       := round(COALESCE(p_impuestos_internos, 0), 2);
    v_total    := p_total;
$a$;
  v_r2 text := $r$    v_subtotal := round(COALESCE(p_subtotal, 0), 2);
    v_iva      := round(COALESCE(p_iva, 0), 2);
    v_ii       := round(COALESCE(p_impuestos_internos, 0), 2);
    v_total    := round(p_total, 2);

    /* #1557 (CMP-2) · EL AJUSTE CUADRA Y NO PASA LO QUE LE QUEDA A LA COMPRA.
       Sobre una compra de 1.210 entraba un ajuste de 50.000, y el gerencial lo
       sumaba a «Descuentos de proveedores»; y entraba 100 + 21 con total 9.999.
       Lo que le queda es el total de la compra menos todas sus notas (las
       notas no se anulan). El FOR UPDATE de las líneas de la compra, de más
       arriba, serializa dos notas sobre la misma compra: la segunda cuenta a
       la primera. Un NaN o un infinito no pasa: el cuadre lo da distinto y
       el tope lo ve mayor que todo. */
    IF v_subtotal + v_iva + v_ii IS DISTINCT FROM v_total THEN
      RETURN jsonb_build_object('success', false, 'error',
        format('El total de la nota (%s) tiene que ser el subtotal (%s) más el IVA (%s) más los impuestos internos (%s)',
               v_total, v_subtotal, v_iva, v_ii));
    END IF;

    SELECT c.total - COALESCE((SELECT sum(nc.total) FROM notas_credito nc
                                WHERE nc.compra_id = c.id AND nc.sucursal_id = c.sucursal_id), 0)
      INTO v_resta
      FROM compras c
     WHERE c.id = p_compra_id AND c.sucursal_id = v_sucursal;

    IF NOT (v_total <= v_resta) THEN
      RETURN jsonb_build_object('success', false, 'error',
        format('La nota de crédito (%s) supera lo que le queda a la compra (%s, su total menos las notas que ya tiene). '
               || 'Si la pantalla mostraba otro máximo, recargala: puede haber otra nota de crédito sobre esta compra.',
               v_total, GREATEST(v_resta, 0)));
    END IF;
$r$;
  v_n int;
BEGIN
  IF position(E'\r' in v_def) > 0 THEN
    RAISE EXCEPTION 'mig NNN · registrar_nota_credito viene en CRLF: las anclas son LF';
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_a1, ''))) / length(v_a1);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_nota_credito: el ancla 1 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  v_n := (length(v_def) - length(replace(v_def, v_a2, ''))) / length(v_a2);
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · registrar_nota_credito: el ancla 2 aparece % vez/veces y se esperaba 1', v_n;
  END IF;
  EXECUTE replace(replace(v_def, v_a1, v_r1), v_a2, v_r2);
END
$parche_nc$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el
-- repo; el trigger está; ninguna compra tiene id sin nombre
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
  v_n int;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.compras_guarda_proveedor_nombre()', '3356cd4489b78c814ba5f77a837c7b6b', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.eliminar_proveedor(bigint)', '9e919f139995adeb9c15b073a73fe427', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.registrar_nota_credito(bigint,character varying,text,numeric,numeric,numeric,uuid,jsonb,numeric)',
     '0d8e6a37766fc3f010e3fb34aeab14df', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;

  IF NOT EXISTS (SELECT 1 FROM pg_trigger
                  WHERE tgrelid = 'public.compras'::regclass
                    AND tgname = 'trg_compras_guarda_proveedor_nombre'
                    AND tgenabled = 'O') THEN
    RAISE EXCEPTION 'mig NNN · el trigger trg_compras_guarda_proveedor_nombre no quedó';
  END IF;

  SELECT count(*) INTO v_n FROM public.compras WHERE proveedor_id IS NOT NULL AND proveedor_nombre IS NULL;
  IF v_n > 0 THEN
    RAISE EXCEPTION 'mig NNN · quedan % compras con proveedor y sin nombre', v_n;
  END IF;
END
$post$;

COMMIT;
