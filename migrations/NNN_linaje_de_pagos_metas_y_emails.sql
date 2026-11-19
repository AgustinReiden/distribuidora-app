-- =========================================================================
-- NNN · EL LINAJE DE UN PAGO Y LOS PRODUCTOS DE UNA META, DE SU SUCURSAL; Y EL EMAIL DE
--       OTRO USUARIO POR RPC (plan #1603, ola 2, tanda 5, tarjeta C6: 1601-b9 y la RPC
--       de 1601-b5 de #1601)
--
-- Ensayo: scripts/test-linaje-pagos-metas-y-emails-ola2-1603.sql. Se aplica en LF, en una
-- sola transacción o sentencia por sentencia.
-- Va SOLA: no depende de los cierres de permisos ni de la de facturas de la misma tarjeta.
--
-- QUÉ PASABA
--   · pagos.pago_padre_id y pagos.pago_origen_id (de qué pago salió un pedazo y cuál es su
--     raíz, #1292 y #1359) no tenían FK: un pedazo podía colgarse de un pago de otra
--     sucursal, y check-sucursal-cruzada no lo veía (ve sólo los pares con FK).
--   · metas_preventista.producto_ids es un array: nada miraba que cada id fuera un producto
--     de la sucursal de la meta. Lo validaba sólo guardar_meta_preventista; otro camino, o
--     borrar un producto que está en una meta, dejaba ids colgando.
--   · El email de los demás usuarios se leía de perfiles por REST (D53 lo deja para admin y
--     encargado): faltaba la lectura que lo acota.
--
-- POR QUÉ NO HAY FK EN pagos (decisión de la coordinación, revisión de C6)
--   El linaje sobrevive al borrado del padre a propósito: desafectar_sobrepago_pedido borra
--   el crédito de NC y hace nacer el pedazo con el padre borrado (#1359); el admin borra lo
--   que quedó de un pago partido; anular_salvedad (C1) repone el cobro con las marcas del
--   recortado, que puede estar borrado; y _rendicion_pagos sube la cadena contra la foto.
--   Una FK a pagos rompe esos caminos (23503), y SET NULL cambia la plata de las
--   rendiciones. Un registro aparte de ids (probado) suma un INSERT por cobro y dos modos de
--   falla nuevos (los pagos borrados antes de crearlo; un id reutilizado tras una
--   restauración), con 0 pedazos en producción. Se cierra así:
--     · un trigger que rechaza al nacer (o al cambiar) un pedazo cuyo padre o raíz VIVOS son
--       de otra sucursal; si el padre o la raíz ya no existen, pasa (es legítimo);
--     · PAGO-B en auditoria_integridad(): pedazos con la raíz viva en otra sucursal (el
--       padre ya lo mira PAGO-A).
--
-- QUÉ CAMBIA
--   1 · trg_pagos_linaje_de_su_sucursal (BEFORE INSERT OR UPDATE OF pago_padre_id,
--       pago_origen_id, sucursal_id ON pagos, sólo cuando alguna de las dos no es NULL: el
--       cobro común no lo dispara).
--   2 · metas_preventista: trg_metas_productos_de_su_sucursal (BEFORE INSERT o UPDATE de
--       producto_ids o sucursal_id) rechaza un id nulo, repetido o que no sea un producto de
--       la sucursal de la meta.
--   3 · productos: trg_productos_rechazar_borrado_en_meta (BEFORE DELETE): un producto que
--       está en una meta no se borra, se desactiva (decisión del dueño del 19/11).
--   4 · auditoria_integridad(): PAGO-B y META-A (metas con un producto nulo, repetido,
--       borrado o de otra sucursal; cubre también un producto que se mudó de sucursal a
--       mano). Por ancla, sin md5: otras tarjetas le suman checks (C5: ROT-A/B/C y SEG-C,
--       con la misma ancla, que sigue apareciendo una vez después de cada una).
--   5 · emails_de_usuarios(uuid[]) (D53): el email de otro, sólo para admin y encargado; a
--       cada uno, el suyo. El front de la tarjeta (#1670) la usa, y mientras no existe lee
--       la tabla como siempre.
--
-- EMBEDS DE POSTGREST: no hay FK nuevas; ningún embed cambia, tampoco en un bundle viejo.
--
-- LOCKS: un LOCK al principio y NOWAIT, SHARE ROW EXCLUSIVE sobre pagos, metas_preventista
-- y productos (lo que toman los CREATE TRIGGER; deja leer y frena las escrituras mientras
-- dura la migración, que no recorre ninguna tabla salvo las premisas).
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
  v_cruzados bigint;
  v_metas    bigint;
  v_ancla    text := $a$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$a$;
  v_def      text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  IF to_regprocedure('public.emails_de_usuarios(uuid[])') IS NOT NULL
     OR to_regprocedure('public.pagos_linaje_de_su_sucursal()') IS NOT NULL THEN
    RAISE EXCEPTION 'premisa · emails_de_usuarios o pagos_linaje_de_su_sucursal ya existen: ¿la migración ya se aplicó?';
  END IF;
  IF to_regprocedure('public.perfil_de_sucursal_activa(uuid)') IS NULL
     OR to_regprocedure('public.admin_comparte_sucursal_con(uuid)') IS NULL THEN
    RAISE EXCEPTION 'premisa · faltan los helpers de visibilidad de perfiles';
  END IF;
  IF (SELECT format_type(atttypid, atttypmod) FROM pg_attribute
       WHERE attrelid = 'public.metas_preventista'::regclass AND attname = 'producto_ids') <> 'bigint[]' THEN
    RAISE EXCEPTION 'premisa · metas_preventista.producto_ids no es bigint[]';
  END IF;
  IF (length(v_def) - length(replace(v_def, v_ancla, ''))) / length(v_ancla) <> 1 THEN
    RAISE EXCEPTION 'premisa · el ancla de auditoria_integridad() no aparece exactamente una vez';
  END IF;
  IF v_def ~ '''(PAGO-B|META-A)''' THEN
    RAISE EXCEPTION 'premisa · auditoria_integridad() ya tiene PAGO-B o META-A';
  END IF;

  -- Un pedazo con el padre o la raíz VIVOS en otra sucursal.
  SELECT count(*) INTO v_cruzados
    FROM pagos h
    JOIN pagos r ON r.id IN (h.pago_padre_id, h.pago_origen_id)
   WHERE r.sucursal_id <> h.sucursal_id;
  -- Una meta con un producto nulo, repetido, inexistente o de otra sucursal.
  SELECT count(*) INTO v_metas
    FROM metas_preventista m
   WHERE m.producto_ids IS NOT NULL
     AND (array_position(m.producto_ids, NULL) IS NOT NULL
          OR cardinality(m.producto_ids) <> (SELECT count(DISTINCT x) FROM unnest(m.producto_ids) x)
          OR EXISTS (SELECT 1 FROM unnest(m.producto_ids) x
                      WHERE NOT EXISTS (SELECT 1 FROM productos p
                                         WHERE p.id = x AND p.sucursal_id = m.sucursal_id)));
  IF v_cruzados > 0 OR v_metas > 0 THEN
    RAISE EXCEPTION 'premisa · % pedazos de pago con el padre o la raíz en otra sucursal y % metas con productos nulos, repetidos, borrados o ajenos. Revisar a mano antes de aplicar.',
      v_cruzados, v_metas;
  END IF;
END
$premisas$;

-- -------------------------------------------------------------------------
-- 1 · El linaje de un pago, de su sucursal
-- -------------------------------------------------------------------------
CREATE FUNCTION public.pagos_linaje_de_su_sucursal()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  -- 1601-b9 (#1601): el padre o la raíz de un pedazo, si existen, son de su sucursal. Si
  -- ya no existen pasa: el linaje sobrevive al borrado del padre a propósito (#1359,
  -- desafectar_sobrepago_pedido; anular_salvedad repone con las marcas del recortado).
  -- Definer: tiene que ver el pago de otra sucursal aunque quien escribe no lo vea por RLS.
  -- El mensaje dice sólo ids.
  IF EXISTS (SELECT 1 FROM pagos r
              WHERE r.id IN (NEW.pago_padre_id, NEW.pago_origen_id)
                AND r.sucursal_id <> NEW.sucursal_id) THEN
    RAISE EXCEPTION 'El pago nombra como padre (#%) o raíz (#%) un pago de otra sucursal.',
      NEW.pago_padre_id, NEW.pago_origen_id USING ERRCODE = '23503';
  END IF;
  RETURN NEW;
END;
$function$;

REVOKE ALL ON FUNCTION public.pagos_linaje_de_su_sucursal() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_pagos_linaje_de_su_sucursal
  BEFORE INSERT OR UPDATE OF pago_padre_id, pago_origen_id, sucursal_id ON public.pagos
  FOR EACH ROW
  WHEN (NEW.pago_padre_id IS NOT NULL OR NEW.pago_origen_id IS NOT NULL)
  EXECUTE FUNCTION public.pagos_linaje_de_su_sucursal();

-- -------------------------------------------------------------------------
-- 2 · Los productos de una meta, de su sucursal
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

-- -------------------------------------------------------------------------
-- 3 · Un producto que está en una meta no se borra
-- -------------------------------------------------------------------------
CREATE FUNCTION public.productos_rechazar_borrado_en_meta()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_metas text;
BEGIN
  -- 1601-b9 (#1601; decisión del dueño del 19/11: se rechaza). Como el resto del historial
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
-- 4 · auditoria_integridad(): PAGO-B y META-A (por ancla, sin md5)
-- -------------------------------------------------------------------------
DO $integridad$
DECLARE
  v_def   text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
  v_ancla text := $a$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$a$;
BEGIN
  v_def := replace(v_def, v_ancla, $n$,
    -- 1601-b9 (#1601) · la raíz de un pedazo, si está viva, es de su sucursal (el padre lo
    -- mira PAGO-A). No hay FK: el linaje sobrevive al borrado del padre a propósito; nacer
    -- cruzado lo frena trg_pagos_linaje_de_su_sucursal, y esto ve lo que se escape.
    ('PAGO-B','high','pedazos de pago con la raíz viva en otra sucursal (1601-b9)',
      (SELECT count(*) FROM pagos h
         JOIN pagos r ON r.id = h.pago_origen_id
        WHERE r.sucursal_id <> h.sucursal_id)),
    -- 1601-b9 · cada producto de una meta es un producto de su sucursal, sin nulos ni
    -- repetidos (lo frena trg_metas_productos_de_su_sucursal al escribir la meta; esto ve
    -- además un producto que se mudó de sucursal a mano).
    ('META-A','high','metas con un producto nulo, repetido, borrado o de otra sucursal (1601-b9)',
      (SELECT count(*) FROM metas_preventista m
        WHERE m.producto_ids IS NOT NULL
          AND (array_position(m.producto_ids, NULL) IS NOT NULL
               OR cardinality(m.producto_ids) <> (SELECT count(DISTINCT x) FROM unnest(m.producto_ids) x)
               OR EXISTS (SELECT 1 FROM unnest(m.producto_ids) x
                           WHERE NOT EXISTS (SELECT 1 FROM productos p
                                              WHERE p.id = x AND p.sucursal_id = m.sucursal_id)))))$n$ || v_ancla);
  -- La regla del search_path (B15): termina en pg_temp. Si ya lo tenía, no cambia.
  IF v_def !~ 'SET search_path TO [^\n]*pg_temp' THEN
    v_def := regexp_replace(v_def, '(SET search_path TO [^\n]*)', '\1, ''pg_temp''');
  END IF;
  EXECUTE v_def;
END
$integridad$;

-- -------------------------------------------------------------------------
-- 5 · emails_de_usuarios: el email de otro, sólo para admin y encargado (D53)
-- -------------------------------------------------------------------------
CREATE FUNCTION public.emails_de_usuarios(p_ids uuid[])
RETURNS TABLE (id uuid, email text)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
  -- 1601-b5 (#1601, decisión del dueño D53): los emails de los demás usuarios los leen admin
  -- y encargado; cada uno, el suyo. A quién ve cada uno es lo mismo que las policies de
  -- SELECT de perfiles: su sucursal activa (perfiles_select_sucursal) y, el admin, quien
  -- comparte alguna sucursal con él (perfiles_select_admin). Un desactivado no es admin ni
  -- encargado (#1474): recibe sólo el suyo.
  SELECT p.id, p.email
    FROM perfiles p
   WHERE p.id = ANY(p_ids)
     AND (p.id = auth.uid()
          OR (es_encargado_o_admin()
              AND (perfil_de_sucursal_activa(p.id) OR admin_comparte_sucursal_con(p.id))));
$function$;

REVOKE ALL ON FUNCTION public.emails_de_usuarios(uuid[]) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.emails_de_usuarios(uuid[]) TO authenticated;

-- -------------------------------------------------------------------------
-- 6 · Poscondición
-- -------------------------------------------------------------------------
DO $post$
BEGIN
  IF (SELECT count(*) FROM pg_trigger
       WHERE NOT tgisinternal AND tgname IN ('trg_pagos_linaje_de_su_sucursal', 'trg_metas_productos_de_su_sucursal',
                                             'trg_productos_rechazar_borrado_en_meta')) <> 3 THEN
    RAISE EXCEPTION 'poscondición · faltan triggers';
  END IF;
  IF has_function_privilege('authenticated', 'public.pagos_linaje_de_su_sucursal()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.metas_productos_de_su_sucursal()', 'EXECUTE')
     OR has_function_privilege('authenticated', 'public.productos_rechazar_borrado_en_meta()', 'EXECUTE')
     OR has_function_privilege('anon', 'public.emails_de_usuarios(uuid[])', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.emails_de_usuarios(uuid[])', 'EXECUTE') THEN
    RAISE EXCEPTION 'poscondición · los permisos de las funciones nuevas no son los esperados';
  END IF;
  IF (SELECT count(*) FROM regexp_matches(
        (SELECT prosrc FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure), '''(PAGO-B|META-A)''', 'g')) <> 2
     OR NOT EXISTS (SELECT 1 FROM pg_proc WHERE oid = 'public.auditoria_integridad()'::regprocedure
                       AND 'search_path=public, pg_temp' = ANY(proconfig)) THEN
    RAISE EXCEPTION 'poscondición · auditoria_integridad() no tiene PAGO-B y META-A, o su search_path no termina en pg_temp';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_proc
              WHERE oid IN ('public.pagos_linaje_de_su_sucursal()'::regprocedure,
                            'public.metas_productos_de_su_sucursal()'::regprocedure,
                            'public.productos_rechazar_borrado_en_meta()'::regprocedure,
                            'public.emails_de_usuarios(uuid[])'::regprocedure)
                AND NOT ('search_path=public, pg_temp' = ANY(proconfig))) THEN
    RAISE EXCEPTION 'poscondición · una función nueva no termina su search_path en pg_temp';
  END IF;
END
$post$;

COMMIT;
