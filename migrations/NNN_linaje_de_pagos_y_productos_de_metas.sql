-- =========================================================================
-- NNN · EL LINAJE DE UN PAGO Y LOS PRODUCTOS DE UNA META, ATADOS A SU SUCURSAL
--       (plan #1603, ola 2, tanda 5, tarjeta C6: 1601-b9 de #1601)
--
-- Ensayo: scripts/test-linaje-pagos-y-metas-ola2-1603.sql. Se aplica en LF.
-- Va SOLA: no depende de la migración de cierres de la misma tarjeta (los REVOKE
-- y el bucket de facturas), que se aplica cuando no queden bundles viejos.
--
-- QUÉ PASABA
--   · pagos.pago_padre_id y pagos.pago_origen_id (de qué pago salió un pedazo y
--     cuál es su raíz, #1292 y #1359) no tenían FK: un pedazo podía colgarse de un
--     pago de otra sucursal o de un id que nunca existió, y check-sucursal-cruzada
--     no los veía (ve sólo los pares con FK).
--   · metas_preventista.producto_ids es un array: ninguna FK mira que cada id sea un
--     producto de la sucursal de la meta. Hoy lo valida sólo guardar_meta_preventista;
--     otro camino que escriba la tabla, o borrar un producto que está en una meta,
--     deja ids colgando.
--
-- POR QUÉ NO ES UNA FK DE pagos A pagos
--   El linaje sobrevive al borrado del padre, a propósito:
--     · desafectar_sobrepago_pedido (la baja de total de una boleta): el crédito de
--       una NC que la boleta ya no necesita se BORRA y enseguida nace un pedazo con
--       pago_padre_id = el id borrado («su padre es el pago recortado, aunque se haya
--       borrado», #1359).
--     · el admin borra por REST lo que quedó de un pago partido, en un día abierto, y
--       su pedazo sigue siendo plata que entró (lo dice PAGO-A de auditoria_integridad).
--     · _rendicion_pagos sube la cadena por pago_padre_id y la cruza con la foto de la
--       rendición, que conserva los pagos borrados después: un padre puesto en NULL
--       volvería a contar vivo un pedazo de un día cerrado.
--   Con una FK (pago_padre_id, sucursal_id) -> pagos(id, sucursal_id) los dos primeros
--   caminos dan 23503 (y el primero rompe la salvedad y la edición que bajan el total);
--   con ON DELETE SET NULL el tercero cambia la plata de las rendiciones. Así que la FK
--   apunta a un REGISTRO de los ids de pago con su sucursal, que no se borra nunca:
--   pagos_linaje. Cada pago que nace entra ahí (trigger AFTER INSERT). La FK garantiza
--   que el padre y la raíz de un pedazo fueron un pago de SU sucursal, aunque hoy ya no
--   estén; que el padre vivo tenga la misma raíz lo sigue mirando PAGO-A.
--
-- QUÉ CAMBIA
--   1 · Tabla nueva pagos_linaje (id, sucursal_id): de server (sin grants para
--       authenticated ni anon, RLS sin policies), llena con todos los pagos de hoy y con
--       los ids de padres o raíces ya borrados, con la sucursal del pedazo que los nombra.
--   2 · Trigger trg_pagos_linaje_registrar (AFTER INSERT ON pagos): anota el pago nuevo.
--   3 · FK compuestas pagos_pago_padre_id_fkey y pagos_pago_origen_id_fkey:
--       (pago_padre_id | pago_origen_id, sucursal_id) -> pagos_linaje(id, sucursal_id).
--   4 · metas_preventista: trg_metas_productos_de_su_sucursal (BEFORE INSERT o UPDATE de
--       producto_ids o sucursal_id) rechaza un id nulo, repetido o que no sea un producto
--       de la sucursal de la meta.
--   5 · productos: trg_productos_rechazar_borrado_en_meta (BEFORE DELETE) rechaza borrar
--       un producto que está en una meta de su sucursal, como el resto del historial: se
--       desactiva. (PREGUNTA ABIERTA AL DUEÑO: la otra opción es quitarlo de la meta.)
--
-- EMBEDS DE POSTGREST (trampa 5 de CLAUDE.md)
--   Las FK nuevas van de pagos a pagos_linaje, una tabla que nadie lee por REST: no hay
--   ningún embed entre las dos ni entre pagos_linaje y otra (src/ y supabase/functions/),
--   y no cambia ninguna relación entre tablas que ya tenían FK. Los embeds de pagos que
--   hay (`pagos(...)` desde pedidos, `usuario:perfiles(id, nombre)` desde pagos) siguen
--   con una sola relación cada uno, también en un bundle viejo del PWA. metas y productos
--   no suman FK.
--
-- LOCKS
--   Un LOCK por modo, al principio y NOWAIT: SHARE ROW EXCLUSIVE sobre pagos,
--   metas_preventista y productos (alcanza para CREATE TRIGGER y para la FK; deja leer
--   y frena las escrituras mientras dura). La FK valida recorriendo pagos una vez.
--
-- Medir en producción antes de aplicar: las consultas de sólo lectura del informe de la
-- tarjeta C6 (filas que hoy violarían cada regla). La premisa de abajo aborta igual si
-- las hay.
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

LOCK TABLE public.pagos, public.metas_preventista, public.productos IN SHARE ROW EXCLUSIVE MODE NOWAIT;

-- -------------------------------------------------------------------------
-- 0 · Premisas: el esquema que se espera y los datos que cumplen
-- -------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_cruzados   bigint;
  v_choques    bigint;
  v_metas      bigint;
BEGIN
  IF to_regclass('public.pagos_linaje') IS NOT NULL THEN
    RAISE EXCEPTION 'premisa · pagos_linaje ya existe: ¿la migración ya se aplicó?';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_constraint
              WHERE conrelid = 'public.pagos'::regclass AND contype = 'f'
                AND conname IN ('pagos_pago_padre_id_fkey', 'pagos_pago_origen_id_fkey')) THEN
    RAISE EXCEPTION 'premisa · pagos ya tiene una FK de linaje';
  END IF;
  IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
       WHERE attrelid = 'public.pagos'::regclass AND attname = 'pago_padre_id') <> 'bigint'
     OR (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
          WHERE attrelid = 'public.pagos'::regclass AND attname = 'pago_origen_id') <> 'bigint'
     OR (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
          WHERE attrelid = 'public.metas_preventista'::regclass AND attname = 'producto_ids') <> 'bigint[]' THEN
    RAISE EXCEPTION 'premisa · los tipos de pago_padre_id, pago_origen_id o producto_ids no son los esperados';
  END IF;

  -- Un pedazo cuyo padre o raíz VIVO está en otra sucursal.
  SELECT count(*) INTO v_cruzados
    FROM pagos h
    JOIN pagos r ON r.id IN (h.pago_padre_id, h.pago_origen_id)
   WHERE r.sucursal_id <> h.sucursal_id;
  -- Un id de padre o raíz BORRADO que nombran pedazos de dos sucursales distintas: no se
  -- puede registrar con una sola.
  SELECT count(*) INTO v_choques
    FROM (SELECT x.ref
            FROM pagos h
           CROSS JOIN LATERAL (VALUES (h.pago_padre_id), (h.pago_origen_id)) x(ref)
           WHERE x.ref IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM pagos v WHERE v.id = x.ref)
           GROUP BY x.ref
          HAVING count(DISTINCT h.sucursal_id) > 1) c;
  IF v_cruzados > 0 OR v_choques > 0 THEN
    RAISE EXCEPTION 'premisa · linaje de pagos que cruza de sucursal: % pedazos con el padre o la raíz vivos en otra sucursal, % ids borrados nombrados desde dos sucursales. Revisar a mano antes de aplicar.',
      v_cruzados, v_choques;
  END IF;

  -- Una meta con un producto nulo, repetido, inexistente o de otra sucursal.
  SELECT count(*) INTO v_metas
    FROM metas_preventista m
   WHERE m.producto_ids IS NOT NULL
     AND (array_position(m.producto_ids, NULL) IS NOT NULL
          OR cardinality(m.producto_ids) <> (SELECT count(DISTINCT x) FROM unnest(m.producto_ids) x)
          OR EXISTS (SELECT 1 FROM unnest(m.producto_ids) x
                      WHERE NOT EXISTS (SELECT 1 FROM productos p
                                         WHERE p.id = x AND p.sucursal_id = m.sucursal_id)));
  IF v_metas > 0 THEN
    RAISE EXCEPTION 'premisa · % metas con un producto nulo, repetido, borrado o de otra sucursal. Revisar a mano antes de aplicar.', v_metas;
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · El registro de los ids de pago
-- -------------------------------------------------------------------------
CREATE TABLE public.pagos_linaje (
  id          bigint PRIMARY KEY,
  sucursal_id bigint NOT NULL REFERENCES public.sucursales(id),
  CONSTRAINT pagos_linaje_id_sucursal_uk UNIQUE (id, sucursal_id)
);

COMMENT ON TABLE public.pagos_linaje IS
  'Cada id de pago que existió, con su sucursal (#1601, 1601-b9). No se borra nunca: es el padre de las FK de linaje de pagos (pago_padre_id, pago_origen_id), que tienen que sobrevivir al borrado del pago padre. Sólo de server.';

ALTER TABLE public.pagos_linaje ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.pagos_linaje FROM PUBLIC, anon, authenticated;

INSERT INTO public.pagos_linaje (id, sucursal_id)
SELECT id, sucursal_id FROM public.pagos;

-- Los padres y las raíces ya borrados, con la sucursal del pedazo que los nombra (la
-- premisa garantiza que es una sola por id).
INSERT INTO public.pagos_linaje (id, sucursal_id)
SELECT DISTINCT x.ref, h.sucursal_id
  FROM public.pagos h
 CROSS JOIN LATERAL (VALUES (h.pago_padre_id), (h.pago_origen_id)) x(ref)
 WHERE x.ref IS NOT NULL
   AND NOT EXISTS (SELECT 1 FROM public.pagos v WHERE v.id = x.ref);

-- -------------------------------------------------------------------------
-- 2 · Cada pago que nace entra al registro
-- -------------------------------------------------------------------------
CREATE FUNCTION public.pagos_linaje_registrar()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  -- 1601-b9 (#1601): el registro no se borra; la FK de linaje de un pedazo que nazca
  -- de este pago lo encuentra aunque este pago se borre después.
  INSERT INTO pagos_linaje (id, sucursal_id) VALUES (NEW.id, NEW.sucursal_id);
  RETURN NULL;
END;
$function$;

REVOKE ALL ON FUNCTION public.pagos_linaje_registrar() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pagos_linaje_registrar
  AFTER INSERT ON public.pagos
  FOR EACH ROW
  EXECUTE FUNCTION public.pagos_linaje_registrar();

-- -------------------------------------------------------------------------
-- 3 · Las FK de linaje, compuestas con la sucursal
-- -------------------------------------------------------------------------
ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_pago_padre_id_fkey
  FOREIGN KEY (pago_padre_id, sucursal_id) REFERENCES public.pagos_linaje(id, sucursal_id);

ALTER TABLE public.pagos
  ADD CONSTRAINT pagos_pago_origen_id_fkey
  FOREIGN KEY (pago_origen_id, sucursal_id) REFERENCES public.pagos_linaje(id, sucursal_id);

-- -------------------------------------------------------------------------
-- 4 · Los productos de una meta, de su sucursal
-- -------------------------------------------------------------------------
CREATE FUNCTION public.metas_productos_de_su_sucursal()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_ajenos integer;
BEGIN
  IF NEW.producto_ids IS NULL THEN
    RETURN NEW;
  END IF;
  -- 1601-b9 (#1601): la FK que un array no puede tener. Sólo cuenta: el mensaje no
  -- dice nada de un producto que quien llama no puede ver.
  IF array_position(NEW.producto_ids, NULL) IS NOT NULL THEN
    RAISE EXCEPTION 'La meta tiene un producto vacío en la lista.' USING ERRCODE = '23502';
  END IF;
  IF cardinality(NEW.producto_ids) <> (SELECT count(DISTINCT x) FROM unnest(NEW.producto_ids) x) THEN
    RAISE EXCEPTION 'La meta repite un producto en la lista.' USING ERRCODE = '23505';
  END IF;
  SELECT count(*) INTO v_ajenos
    FROM unnest(NEW.producto_ids) x
   WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id = x AND p.sucursal_id = NEW.sucursal_id);
  IF v_ajenos > 0 THEN
    RAISE EXCEPTION '% producto(s) de la meta no existen en su sucursal.', v_ajenos USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.metas_productos_de_su_sucursal() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_metas_productos_de_su_sucursal
  BEFORE INSERT OR UPDATE OF producto_ids, sucursal_id ON public.metas_preventista
  FOR EACH ROW
  EXECUTE FUNCTION public.metas_productos_de_su_sucursal();

CREATE FUNCTION public.productos_rechazar_borrado_en_meta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_metas text;
BEGIN
  -- 1601-b9 (#1601): el lado del borrado de la FK del array. Como el resto del historial
  -- (productos_rechazar_borrado_con_historial), el producto se desactiva. Definer: la meta
  -- de otro preventista no la ve por RLS quien borra, y tiene que frenarlo igual. El
  -- mensaje dice sólo los números de meta, de la misma sucursal que el producto.
  SELECT string_agg('#' || m.id, ', ' ORDER BY m.id) INTO v_metas
    FROM metas_preventista m
   WHERE m.sucursal_id = OLD.sucursal_id
     AND OLD.id = ANY(m.producto_ids);
  IF v_metas IS NOT NULL THEN
    RAISE EXCEPTION 'No se puede borrar el producto #%: está en las metas %. Desactivalo en lugar de borrarlo, o sacalo de esas metas.',
      OLD.id, v_metas USING ERRCODE = '23503';
  END IF;
  RETURN OLD;
END;
$function$;

REVOKE ALL ON FUNCTION public.productos_rechazar_borrado_en_meta() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_productos_rechazar_borrado_en_meta
  BEFORE DELETE ON public.productos
  FOR EACH ROW
  EXECUTE FUNCTION public.productos_rechazar_borrado_en_meta();

-- -------------------------------------------------------------------------
-- 5 · Poscondición
-- -------------------------------------------------------------------------
DO $post$
BEGIN
  IF (SELECT count(*) FROM pg_constraint
       WHERE conrelid = 'public.pagos'::regclass AND contype = 'f' AND convalidated
         AND confrelid = 'public.pagos_linaje'::regclass) <> 2 THEN
    RAISE EXCEPTION 'poscondición · faltan las dos FK de linaje validadas';
  END IF;
  IF EXISTS (SELECT 1 FROM public.pagos p WHERE NOT EXISTS (SELECT 1 FROM public.pagos_linaje l WHERE l.id = p.id AND l.sucursal_id = p.sucursal_id)) THEN
    RAISE EXCEPTION 'poscondición · hay pagos fuera del registro';
  END IF;
  IF has_table_privilege('authenticated', 'public.pagos_linaje', 'SELECT')
     OR has_table_privilege('anon', 'public.pagos_linaje', 'SELECT')
     OR has_function_privilege('authenticated', 'public.pagos_linaje_registrar()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.metas_productos_de_su_sucursal()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.productos_rechazar_borrado_en_meta()', 'EXECUTE') THEN
    RAISE EXCEPTION 'poscondición · los permisos de los objetos nuevos no son los esperados';
  END IF;
  IF (SELECT count(*) FROM pg_trigger
       WHERE NOT tgisinternal AND tgname IN ('trg_pagos_linaje_registrar', 'trg_metas_productos_de_su_sucursal',
                                             'trg_productos_rechazar_borrado_en_meta')) <> 3 THEN
    RAISE EXCEPTION 'poscondición · faltan triggers';
  END IF;
END
$post$;

COMMIT;
