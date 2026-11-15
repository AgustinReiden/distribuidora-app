-- =========================================================================
-- NNN · LA FECHA DE ENTREGA TIENE PISO Y TECHO, Y UN PEDIDO SIN CHOFER NO
--       DEJA PASAR A CUALQUIERA A MARCAR LA NO ENTREGA
--       (GTO-15 #1597, 1598-b2 #1598, SEG-1 #1601)
--
-- Una función nueva (`_fecha_entrega_fuera_de_rango`) y parches por ancla a
-- `marcar_entregas_masivo`, `marcar_entrega_y_pago_masivo_impl`,
-- `pedidos_proteger_columnas`, `marcar_no_entregado` y
-- `auditoria_rpcs_definer`, con premisa de md5 sobre los cuerpos vivos (la 504
-- aplicada) y poscondición de md5, definer y ACL. No cambia tablas ni firmas.
-- Ensayo: scripts/test-fecha-entrega-1597-1601.sql. Se aplica en LF.
--
-- =========================================================================
-- QUÉ PASABA
-- =========================================================================
-- GTO-15 · El piso de 60 días de la fecha de un gasto exime al gasto que sale
-- de una rendición que existe (#1562, `_fecha_rendicion_validar_piso`): ese
-- chofer tiene, ese día, cobros o entregas. Pero la fecha de una entrega no
-- tenía límites: `marcar_entregas_masivo(…, p_fecha)` y
-- `marcar_entrega_y_pago_masivo_impl` (el admin) tomaban cualquier día, y el
-- PATCH del chofer también. Un encargado entregaba un pedido de hoy con fecha
-- de 2016, y con esa "rendición que existe" cargaba gastos de 2016 (con IVA
-- crédito incluido en la posición fiscal de ese mes). La entrega vieja además
-- llevaba la deuda del cliente a 10 años de mora.
-- 1598-b2 · La masiva aceptaba fecha futura.
-- SEG-1 · `marcar_no_entregado` cortaba con
-- `IF NOT (v_transportista = v_uid OR v_rol IN ('admin', 'encargado'))`. Con el
-- pedido sin chofer (`transportista_id` NULL, que es como lo deja esta misma
-- función después de una no entrega) la comparación da NULL, el NOT de NULL
-- es NULL y el IF no corta: cualquier rol de la sucursal (un preventista, el
-- depósito) pisaba el motivo y la nota de la parada y le mandaba el aviso al
-- vendedor.
--
-- =========================================================================
-- QUÉ CAMBIA
-- =========================================================================
-- Decisión del dueño (#1597): quien no es admin fecha una entrega de hoy hasta
-- `politicas_comerciales.dias_atras_fecha_pedido` días atrás (los mismos de la
-- fecha del pedido, 7 sin fila); el admin, hasta 60 días atrás (el piso de un
-- gasto, `_fecha_carga_piso`); nadie con fecha futura. La regla es una,
-- `_fecha_entrega_fuera_de_rango(fecha, sucursal, es_admin)`, que devuelve el
-- motivo o NULL, con espejo en el front (`src/utils/fechaEntrega.ts`). La
-- llaman todos los caminos del usuario que fijan `pedidos.fecha_entrega`:
--   · `marcar_entregas_masivo` y `marcar_entrega_y_pago_masivo_impl`, con la
--     fecha que reciben (sus pedidos todavía no están entregados: la fecha es
--     siempre nueva). En la de cobro, el encargado sigue además en "sólo hoy".
--   · `pedidos_proteger_columnas`, para todo `authenticated` a profundidad 1: el
--     PATCH del chofer (la entrega de a una), el de admin y encargado, y
--     `actualizar_fechas_y_notas_pedido` (INVOKER). Sólo si el día argentino
--     cambia: una entrega vieja ya cargada se sigue tocando (notas, la hora
--     del mismo día, volverla a pendiente).
-- El server (DEFINER, sin sesión) no pasa por la regla.
-- `marcar_no_entregado`: el chofer pasa sólo si es el asignado
-- (`COALESCE(v_transportista = v_uid, false)`), y admin y encargado por
-- `es_encargado_o_admin()`, que además mira `activo` (#1490): sale de
-- `scripts/rol-sin-activo-permitidas.json`.
-- `auditoria_rpcs_definer()->guardas_nulas` (gate de
-- `scripts/check-rpcs-definer.mjs`) ve también la forma
-- `NOT (x = uid OR …)`: hoy sólo la tenía `marcar_no_entregado`.
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
-- Premisas: los cuerpos vivos del 15/11 (la 504 aplicada)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.marcar_entregas_masivo(bigint[],uuid,date)',                 '9501a8cfdd48587000d3432751354141'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '095d9998f7b254e9cdfd2a16b04ec57c'),
    ('public.pedidos_proteger_columnas()',                                '7a96f8fad1e6efee59678ffbbdf67cd5'),
    ('public.marcar_no_entregado(bigint,character varying,text)',         '513a1c6072956c5d839ce5d0d7a34fc1'),
    ('public.auditoria_rpcs_definer()',                                   '35ccb13582403cf6d07c05a593ac3130')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regprocedure('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · _fecha_entrega_fuera_de_rango ya existe';
  END IF;
  -- El piso del admin es el de un gasto: 60 días.
  IF public._fecha_carga_piso() IS DISTINCT FROM public._tablero_hoy() - 60 THEN
    RAISE EXCEPTION 'mig NNN · _fecha_carga_piso() ya no es hoy - 60: revisar el piso del admin';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.politicas_comerciales'::regclass
                    AND attname = 'dias_atras_fecha_pedido' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · politicas_comerciales.dias_atras_fecha_pedido no existe: falta la 481';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla en una definición.
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

-- =========================================================================
-- 1 · La regla: _fecha_entrega_fuera_de_rango
-- =========================================================================
CREATE FUNCTION public._fecha_entrega_fuera_de_rango(p_fecha date, p_sucursal bigint, p_admin boolean)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path TO 'public'
AS $function$
  -- GTO-15 (#1597): por qué la fecha de una entrega no entra, o NULL si entra. Decisión del
  -- dueño: quien no es admin, de hoy (el día argentino) hasta
  -- politicas_comerciales.dias_atras_fecha_pedido días atrás (7 sin fila, los de la fecha del
  -- pedido); el admin, hasta 60 días atrás, el piso de un gasto; nadie con fecha futura. Sin
  -- piso, una entrega vieja fabricaba la rendición que exime al gasto de su piso
  -- (_fecha_rendicion_validar_piso). Los 60 van escritos: _fecha_carga_piso no tiene EXECUTE
  -- para authenticated, y esta función corre así desde el trigger. Si cambia el piso del gasto,
  -- cambia éste. La llaman las dos masivas y pedidos_proteger_columnas (el PATCH y
  -- actualizar_fechas_y_notas_pedido), ésta sólo si el día cambia. Espejo en el front:
  -- src/utils/fechaEntrega.ts, con los mismos textos.
  SELECT CASE
           WHEN p_fecha IS NULL THEN NULL
           WHEN p_fecha > r.hoy THEN format(
             'La fecha de entrega (%s) no puede ser posterior a hoy.',
             to_char(p_fecha, 'DD/MM/YYYY'))
           WHEN p_fecha >= r.hoy - r.dias THEN NULL
           WHEN r.admin THEN format(
             'La fecha de entrega (%s) no puede ser anterior al %s: hasta %s días atrás.',
             to_char(p_fecha, 'DD/MM/YYYY'), to_char(r.hoy - r.dias, 'DD/MM/YYYY'), r.dias)
           WHEN r.dias = 0 THEN format(
             'La fecha de entrega (%s) no puede ser anterior a hoy. Si la entrega es de antes, la carga un admin.',
             to_char(p_fecha, 'DD/MM/YYYY'))
           ELSE format(
             'La fecha de entrega (%s) no puede ser anterior al %s: hasta %s %s atrás. Si la entrega es de antes, la carga un admin.',
             to_char(p_fecha, 'DD/MM/YYYY'), to_char(r.hoy - r.dias, 'DD/MM/YYYY'), r.dias,
             CASE WHEN r.dias = 1 THEN 'día' ELSE 'días' END)
         END
    FROM (SELECT x.hoy, x.admin,
                 CASE WHEN x.admin THEN 60
                      ELSE COALESCE((SELECT pc.dias_atras_fecha_pedido
                                       FROM public.politicas_comerciales pc
                                      WHERE pc.sucursal_id = p_sucursal), 7)
                 END AS dias
            FROM (SELECT public._tablero_hoy() AS hoy, COALESCE(p_admin, false) AS admin) x) r
$function$;

-- La llama pedidos_proteger_columnas, que corre como authenticated.
REVOKE ALL ON FUNCTION public._fecha_entrega_fuera_de_rango(date,bigint,boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._fecha_entrega_fuera_de_rango(date,bigint,boolean) TO authenticated, service_role;

-- =========================================================================
-- 2 · marcar_entregas_masivo
-- =========================================================================
DO $parche_masivo$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entregas_masivo(bigint[],uuid,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  p_fecha := COALESCE(p_fecha, public._tablero_hoy());
$a$,
$r$  p_fecha := COALESCE(p_fecha, public._tablero_hoy());

  -- GTO-15 (#1597) y 1598-b2: la fecha de entrega va de hoy hasta los días atrás de la
  -- política (el admin, 60). Sin piso, una entrega de 2016 fabricaba la rendición que exime
  -- al gasto de ese día de su piso. Los pedidos de acá no están entregados: la fecha es nueva.
  DECLARE
    v_motivo_fecha text := public._fecha_entrega_fuera_de_rango(p_fecha, v_sucursal_id, public.es_admin());
  BEGIN
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END;
$r$, 'marcar_entregas_masivo (rango de la fecha)');

  EXECUTE v_def;
END
$parche_masivo$;

-- =========================================================================
-- 3 · marcar_entrega_y_pago_masivo_impl
-- =========================================================================
DO $parche_masivo_pago$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  p_fecha := COALESCE(p_fecha, public._tablero_hoy());
$a$,
$r$  p_fecha := COALESCE(p_fecha, public._tablero_hoy());

  -- GTO-15 (#1597): la fecha de entrega va de hoy hasta los días atrás de la política (el
  -- admin, 60), como en marcar_entregas_masivo. El encargado sigue además en "sólo hoy" (la
  -- regla del cobro, abajo).
  DECLARE
    v_motivo_fecha text := public._fecha_entrega_fuera_de_rango(p_fecha, v_sucursal_id, public.es_admin());
  BEGIN
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END;
$r$, 'marcar_entrega_y_pago_masivo_impl (rango de la fecha)');

  EXECUTE v_def;
END
$parche_masivo_pago$;

-- =========================================================================
-- 4 · pedidos_proteger_columnas: el PATCH y actualizar_fechas_y_notas_pedido
-- =========================================================================
DO $parche_proteger$
DECLARE
  v_def text := pg_get_functiondef('public.pedidos_proteger_columnas()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$        RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$a$,
$r$        RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
      END IF;
    END IF;
  END IF;

  -- GTO-15 (#1597): la fecha de entrega que pone admin o encargado va de hoy hasta los días
  -- atrás de la política (el admin, 60): su PATCH y actualizar_fechas_y_notas_pedido
  -- (INVOKER). La misma regla que las masivas. Sólo si el día argentino cambia: una entrega
  -- vieja se sigue editando (notas, la hora del mismo día, volverla a pendiente). Va antes de
  -- su salida de abajo; la del chofer, después de la rama de #1317, para que a quien no puede
  -- tocar la fecha le llegue ese motivo y no el del rango.
  IF TG_OP = 'UPDATE' AND NEW.fecha_entrega IS NOT NULL
     AND (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         IS DISTINCT FROM (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
     AND es_encargado_o_admin() THEN
    v_motivo_fecha := public._fecha_entrega_fuera_de_rango(
      (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, OLD.sucursal_id, es_admin());
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END IF;

  IF es_encargado_o_admin() THEN
    RETURN NEW;
  END IF;
$r$, 'pedidos_proteger_columnas (rango de la fecha de entrega, admin y encargado)');

  v_def := pg_temp.parche(v_def,
$a$      RAISE EXCEPTION 'El estado, el chofer y la fecha de entrega del pedido #% los cambia su chofer al entregarlo, o un encargado o administrador.',
        OLD.id USING ERRCODE = '42501';
    END IF;
  END IF;
$a$,
$r$      RAISE EXCEPTION 'El estado, el chofer y la fecha de entrega del pedido #% los cambia su chofer al entregarlo, o un encargado o administrador.',
        OLD.id USING ERRCODE = '42501';
    END IF;
  END IF;

  -- GTO-15 (#1597): la entrega de a una del chofer (su PATCH), con el rango de quien no es
  -- admin. Sólo si el día argentino cambia, como arriba.
  IF NEW.fecha_entrega IS NOT NULL
     AND (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
         IS DISTINCT FROM (OLD.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date THEN
    v_motivo_fecha := public._fecha_entrega_fuera_de_rango(
      (NEW.fecha_entrega AT TIME ZONE 'America/Argentina/Buenos_Aires')::date, OLD.sucursal_id, false);
    IF v_motivo_fecha IS NOT NULL THEN
      RAISE EXCEPTION '%', v_motivo_fecha USING ERRCODE = '22023';
    END IF;
  END IF;
$r$, 'pedidos_proteger_columnas (rango de la fecha de entrega, el chofer)');

  EXECUTE v_def;
END
$parche_proteger$;

-- =========================================================================
-- 5 · marcar_no_entregado: un pedido sin chofer no autoriza a cualquiera
-- =========================================================================
DO $parche_no_entregado$
DECLARE
  v_def text := pg_get_functiondef('public.marcar_no_entregado(bigint,character varying,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  -- Lo puede marcar el chofer al que se le asignó, o un admin/encargado.
  SELECT rol INTO v_rol FROM perfiles WHERE id = v_uid;
  IF NOT (v_transportista = v_uid OR v_rol IN ('admin', 'encargado')) THEN
$a$,
$r$  -- Lo puede marcar el chofer al que se le asignó, o un admin/encargado.
  -- SEG-1 (#1601): sin chofer (transportista_id NULL, como lo deja esta misma función) la
  -- comparación daba NULL, el NOT también, y el IF no cortaba: pasaba cualquier rol de la
  -- sucursal. Un NULL no autoriza a nadie más que a admin y encargado, que se miran con su
  -- helper (activo incluido, #1490).
  IF NOT (COALESCE(v_transportista = v_uid, false) OR public.es_encargado_o_admin()) THEN
$r$, 'marcar_no_entregado (guarda con chofer NULL)');

  EXECUTE v_def;
END
$parche_no_entregado$;

-- =========================================================================
-- 6 · auditoria_rpcs_definer: la guarda NOT (x = uid OR …)
-- =========================================================================
DO $parche_gate$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_rpcs_definer()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$       OR r.src ~ '_rol_en_sucursal\s*\([^()]*(\([^()]*\)[^()]*)*\)\s*(<>|!=|not\s+in\M)' THEN
$a$,
$r$       OR r.src ~ '_rol_en_sucursal\s*\([^()]*(\([^()]*\)[^()]*)*\)\s*(<>|!=|not\s+in\M)'
       -- #1601 (SEG-1): `IF NOT (x = uid OR …)` con x NULL (un pedido sin chofer) da NULL y
       -- el IF no corta. Con COALESCE o IS NOT DISTINCT FROM no la marca.
       OR r.src ~ ('\mnot\s*\(\s*([a-z_][a-z0-9_.]*\s*=\s*(' || v_uid || ')|(' || v_uid
                   || ')\s*=\s*[a-z_][a-z0-9_.]*)\s+or\M') THEN
$r$, 'auditoria_rpcs_definer (guarda NOT (x = uid OR …))');

  EXECUTE v_def;
END
$parche_gate$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._fecha_entrega_fuera_de_rango(date,bigint,boolean)', '966abda7d4a2615071d23d130bb953ee', false,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entregas_masivo(bigint[],uuid,date)', '96f7658823eb86bfc0483259ba7f3789', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.marcar_entrega_y_pago_masivo_impl(bigint[],uuid,text,date)', '08aa2a964a2395ae0400b01fd909d105', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.pedidos_proteger_columnas()', '2ab9c05bb89a01c0633df5e376000e52', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.marcar_no_entregado(bigint,character varying,text)', '7ca8e27aefa489e20a612a9a5591bd21', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.auditoria_rpcs_definer()', 'f0d47494b6632bc5eeca699a88c55880', true,
     '{postgres=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
END
$post$;

COMMIT;
