-- =========================================================================
-- NNN · COMISIONES Y METAS (ola 3, tarjeta T7 de #1677; #1690, #1551, #1554
--       y #1522)
--
-- Ensayo: scripts/test-ola3-t7-comisiones-metas.sql (falla sin esta migración,
-- ENSAYO OK con ella; cada freno con su mutante).
-- Se aplica en LF. DDL de tabla: una tabla nueva, un trigger en perfiles y en
-- comision_reglas, un índice en comision_reglas, una columna en
-- politicas_comerciales y la policy de metas propias. Sus LOCK van al
-- principio, NOWAIT (perfiles en SHARE ROW EXCLUSIVE: el CREATE TRIGGER no
-- frena las lecturas).
--
-- 1 · COM-2 (D3, decisión del dueño del 26/11): lo no liquidado se calcula con
--     el rol que tenía el vendedor AL VENDER, no con el de hoy. Ejemplo: Juan,
--     preventista al 3 %, vendió y entregó $ 300.000 la primera quincena; el 15
--     pasa a encargado (no comisiona); al liquidar cobra sus $ 9.000. Lo que
--     carga después del cambio va con el rol nuevo.
--     Cómo se sabe el rol de cada venta: un historial de cambios de rol
--     (perfil_rol_cambios, sólo de server), que anota un trigger en cada cambio
--     de perfiles.rol, y que nace con los cambios que ya están en audit_logs. El
--     rol de una venta es el que el vendedor tenía cuando se cargó el pedido
--     (pedidos.created_at): el rol_anterior del primer cambio posterior, o el
--     de hoy si no cambió después (_rol_al_momento). _comision_lineas decide
--     el % por defecto con _actua_como_preventista_al (la misma regla que
--     _actua_como_preventista, a ese momento). 'preventista_taco' (un rol que
--     existió en mayo y ya no está en el CHECK) cuenta como preventista: lo
--     tuvo un preventista que hoy lo es, y así sus pedidos pendientes no
--     cambian. Lo liquidado no se mueve: la foto de empleado_liquidacion_lineas
--     guarda su %, y un ajuste usa ese %.
--     Los roles extra de perfil_roles no tienen historial: hoy sólo pueden ser
--     'transportista' (su CHECK), que no comisiona como preventista; se miran
--     como están.
-- 2 · COM-1 (D2, decisión del dueño del 26/11) con Com-B2 y Fr-B8: nadie se fija
--     su propio porcentaje de comisión, tampoco un admin. guardar_comision_regla
--     y desactivar_comision_regla rechazan una regla del propio admin (cargarla,
--     editarla o darla de baja): la carga otro admin, o el server por SQL si hay
--     uno solo. comision_reglas pasa a tener auditoría (audit_comision_reglas), la
--     edición en el lugar anota quién la editó (usuario_id), y el alta no
--     duplica: la misma regla que ya rige desde ese día devuelve la que está
--     (un doble toque), y una con otro % se rechaza con su motivo. Lo cierra un
--     índice único parcial (las reglas activas, por su clave y su día de inicio),
--     que también frena a dos altas a la vez.
--     La pantalla de liquidar muestra los % con que se calculó y quién los cargó:
--     _liquidacion_json suma comisiones.porcentajes.
-- 3 · D11 (reportes-R5, decisión del dueño del 26/11): el % de la simulación de
--     comisiones del gerencial pasa a politicas_comerciales
--     (comision_pct_simulacion, 2 de semilla, de 0 a 100). Es reservado (como
--     los otros % de comisión): lo da politica_comercial_reservada() a admin y
--     encargado, y lo cambia sólo el admin (actualizar_comision_pct_simulacion).
--     reporte_gerencial lo devuelve en kpis.comision_pct_default
--     (_comision_pct_simulacion).
-- 4 · SEG-03 / VTA-09 (decisión del dueño del 27/11): el origen del precio de
--     cada línea lo calcula siempre el server. registrar_origen_precio_items
--     ignora lo que manda el teléfono (p_origenes queda en la firma por los
--     bundles viejos) y etiqueta con _origen_precio_de_lineas: escala del
--     pedido (mayorista), descuento del cliente o de su categoría, lista o
--     manual. La escala de una línea mayorista también la pone el server.
-- 5 · Com-B7 (decisión del dueño del 27/11): lo cobrado con adelanto de sueldo
--     es una venta a un empleado: no suma para las metas, como ya no comisiona.
--     _metas_logrado aplica a cada boleta el mismo factor que _comision_lineas
--     (la parte que no se pagó con adelanto, sobre la venta neta de las notas
--     que restan de esa meta). Ejemplo: boleta de $ 1.000 con $ 400 de
--     adelanto: suma $ 600 a la meta de facturación.
-- 6 · Com-B8 (decisión del dueño del 27/11): un pedido entregado de $ 0 (sólo
--     regalo o sólo canje) o pagado entero con adelanto no cuenta como cliente
--     atendido para la meta de cobertura.
-- 7 · REP-7: calcular_comisiones sin sucursales usa _sucursales_red() (las
--     activas asignadas), no todas las asignadas.
-- 8 · Com-B6 (1562-b5): avance_metas_preventista y la policy de metas propias
--     piden que quien llama esté activo y actúe como preventista
--     (es_preventista(), que da false a un desactivado) o sea admin.
--
-- Lo que NO hace: no toca las funciones de rendiciones ni de cobros (T5), ni
-- liquidar_empleado, previsualizar_liquidacion o _liquidacion_lineas (T6).
-- La venta con adelanto de un preventista: hoy no la puede cargar directo (el
-- alta y el cobro de boleta sólo aceptan formas dinerarias; el FIFO de la ficha
-- es de admin y encargado), y lo que queda (el saldo a favor que nació de un
-- adelanto lo absorbe una boleta nueva) va aparte: toca cobros.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

LOCK TABLE public.comision_reglas IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.politicas_comerciales IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.metas_preventista IN ACCESS EXCLUSIVE MODE NOWAIT;
LOCK TABLE public.perfiles IN SHARE ROW EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de producción en la 559.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._comision_lineas(bigint[])', '8d25423b8f9e83f8a37dc4ea1597ca1a'),
    ('public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)', 'bc9025a19710c37e7055fcab728225fd'),
    ('public.desactivar_comision_regla(bigint)', '7279ab162456cbf74d95b5d66996cca3'),
    ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', '9af0909f1c443bd99b6ecb18a31399d8'),
    ('public.calcular_comisiones(date,date,bigint[])', '0fa0f2d20cb2c11e7148dab78759b8b0'),
    ('public.avance_metas_preventista(uuid,date)', '5d64af98e70b244b8735a95e55a02702'),
    ('public._metas_logrado(bigint[])', '927a1b715a4a28eb08a8b9669c38c9db'),
    ('public.politica_comercial_reservada()', '2fdac527fd48c3e1c33fb1419bb6a9c9'),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', 'fca2960bba46ae5a515a08fafa3da9fa'),
    ('public._liquidacion_json(public.empleados,date,date,numeric)', '91f898e4be9e37699c73dc61b26b2fb7'),
    -- Las que se llaman sin tocarse: su regla es la que se copia o se usa.
    ('public._actua_como_preventista(uuid,bigint)', 'ef86cf93bcd7a2e03a05e35895b2bdf1'),
    ('public._liquidacion_lineas(public.empleados,date)', '3725914b726b3d4bcdb728c0d1cde912'),
    ('public._sucursales_red()', '4a78724955d5f6d24b995cf53581b5f3')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regclass('public.perfil_rol_cambios') IS NOT NULL
     OR to_regprocedure('public._rol_al_momento(uuid,timestamptz)') IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · ya está aplicada (existe perfil_rol_cambios)';
  END IF;
  IF EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.politicas_comerciales'::regclass
                AND attname = 'comision_pct_simulacion' AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · ya está aplicada (existe politicas_comerciales.comision_pct_simulacion)';
  END IF;
  -- El índice único de las reglas activas: hoy no hay dos iguales (en prod no hay reglas).
  IF EXISTS (SELECT 1 FROM public.comision_reglas
              WHERE activo
              GROUP BY COALESCE(sucursal_id, 0), preventista_id, origen_precio, producto_id, categoria_id, vigente_desde
             HAVING count(*) > 1) THEN
    RAISE EXCEPTION 'mig NNN · hay reglas de comisión activas repetidas: resolverlas antes del índice';
  END IF;
  -- Los roles extra siguen siendo sólo de chofer: por eso no llevan historial.
  SELECT pg_get_constraintdef(oid) INTO v FROM pg_constraint
   WHERE conrelid = 'public.perfil_roles'::regclass AND conname = 'perfil_roles_rol_check';
  IF v IS DISTINCT FROM 'CHECK ((rol = ''transportista''::text))' THEN
    RAISE EXCEPTION 'mig NNN · perfil_roles admite otros roles extra (%): el historial de rol tiene que cubrirlos', v;
  END IF;
  -- La policy de metas propias es la de siempre.
  SELECT pg_get_expr(polqual, polrelid) INTO v FROM pg_policy
   WHERE polrelid = 'public.metas_preventista'::regclass AND polname = 'metas_preventista_propio_select';
  IF v IS DISTINCT FROM '(preventista_id = auth.uid())' THEN
    RAISE EXCEPTION 'mig NNN · metas_preventista_propio_select cambió (%): rehacer sobre lo vigente', v;
  END IF;
END
$premisas$;

-- Reemplaza un ancla que tiene que aparecer exactamente p_n veces.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_n int, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n <> p_n THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba %', p_que, v_n, p_n;
  END IF;
  RETURN replace(p_def, p_ancla, p_nuevo);
END
$f$;

-- =========================================================================
-- 1 · COM-2: el rol al vender
-- =========================================================================
-- Sólo de server: sin policy y sin grants (la escribe un trigger definer, la
-- leen las funciones de comisión).
CREATE TABLE public.perfil_rol_cambios (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  usuario_id   uuid NOT NULL REFERENCES public.perfiles(id) ON DELETE CASCADE,
  cambiado_at  timestamptz NOT NULL,
  rol_anterior text NOT NULL,
  rol_nuevo    text NOT NULL,
  cambiado_por uuid,
  -- 'trigger': lo anotó el cambio; 'audit_logs': reconstruido al crear la tabla.
  origen       text NOT NULL DEFAULT 'trigger',
  CONSTRAINT perfil_rol_cambios_origen_check CHECK (origen IN ('trigger', 'audit_logs')),
  CONSTRAINT perfil_rol_cambios_cambia CHECK (rol_anterior <> rol_nuevo)
);
CREATE INDEX perfil_rol_cambios_usuario_momento ON public.perfil_rol_cambios (usuario_id, cambiado_at);
ALTER TABLE public.perfil_rol_cambios ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.perfil_rol_cambios FROM PUBLIC, anon, authenticated;
COMMENT ON TABLE public.perfil_rol_cambios IS
  'COM-2 (#1551, D3): cada cambio de perfiles.rol. El rol de una venta es el que el vendedor tenía al cargarla (_rol_al_momento). Sólo de server.';

-- Los cambios que ya pasaron, de la auditoría de perfiles (desde marzo de 2026).
-- Un UPDATE auditado guarda sólo las columnas que cambiaron.
INSERT INTO public.perfil_rol_cambios (usuario_id, cambiado_at, rol_anterior, rol_nuevo, cambiado_por, origen)
SELECT pf.id, a.created_at, a.old_data->>'rol', a.new_data->>'rol', a.usuario_id, 'audit_logs'
  FROM public.audit_logs a
  JOIN public.perfiles pf ON pf.id::text = a.registro_id
 WHERE a.tabla = 'perfiles' AND a.accion = 'UPDATE'
   AND a.old_data ? 'rol' AND a.new_data ? 'rol'
   AND a.old_data->>'rol' IS DISTINCT FROM a.new_data->>'rol'
   AND a.old_data->>'rol' IS NOT NULL AND a.new_data->>'rol' IS NOT NULL
 ORDER BY a.created_at, a.id;

CREATE FUNCTION public.perfiles_anota_cambio_de_rol()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
BEGIN
  -- COM-2 (#1551): el historial con que se sabe el rol de cada venta.
  INSERT INTO public.perfil_rol_cambios (usuario_id, cambiado_at, rol_anterior, rol_nuevo, cambiado_por)
  VALUES (NEW.id, now(), OLD.rol, NEW.rol, auth.uid());
  RETURN NULL;
END
$function$;
REVOKE EXECUTE ON FUNCTION public.perfiles_anota_cambio_de_rol() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_perfiles_anota_cambio_de_rol
  AFTER UPDATE OF rol ON public.perfiles
  FOR EACH ROW WHEN (OLD.rol IS DISTINCT FROM NEW.rol)
  EXECUTE FUNCTION public.perfiles_anota_cambio_de_rol();

-- El rol que tenía un usuario en un momento: el anterior del primer cambio
-- posterior, o el de hoy si no cambió después.
CREATE FUNCTION public._rol_al_momento(p_usuario uuid, p_momento timestamptz)
RETURNS text
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT COALESCE(
    (SELECT c.rol_anterior FROM public.perfil_rol_cambios c
      WHERE c.usuario_id = p_usuario AND c.cambiado_at > p_momento
      ORDER BY c.cambiado_at, c.id
      LIMIT 1),
    (SELECT p.rol FROM public.perfiles p WHERE p.id = p_usuario));
$function$;
REVOKE EXECUTE ON FUNCTION public._rol_al_momento(uuid, timestamptz) FROM PUBLIC, anon, authenticated;

-- _actua_como_preventista a un momento: rol base preventista, o el extra de esa
-- sucursal sin ser admin ni encargado. 'preventista_taco' (mayo de 2026) es
-- preventista. Sin momento (un pedido sin created_at), el rol de hoy.
CREATE FUNCTION public._actua_como_preventista_al(p_usuario uuid, p_sucursal bigint, p_momento timestamptz)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  SELECT CASE
           WHEN r.rol IS NULL THEN false
           WHEN r.rol IN ('preventista', 'preventista_taco') THEN true
           WHEN r.rol IN ('admin', 'encargado') THEN false
           ELSE EXISTS (SELECT 1 FROM public.perfil_roles pr
                         WHERE pr.usuario_id = p_usuario
                           AND pr.sucursal_id = p_sucursal
                           AND pr.rol = 'preventista')
         END
    FROM (SELECT public._rol_al_momento(p_usuario, p_momento) AS rol) r;
$function$;
REVOKE EXECUTE ON FUNCTION public._actua_como_preventista_al(uuid, bigint, timestamptz) FROM PUBLIC, anon, authenticated;

-- _comision_lineas: el % por defecto con el rol al vender (antes: el de hoy).
DO $comision_lineas$
DECLARE
  v_def text := pg_get_functiondef('public._comision_lineas(bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id,
$a$,
$n$    SELECT p.id, p.usuario_id, p.fecha, p.sucursal_id,
           -- COM-2 (#1551, D3 del dueño del 26/11): el % por defecto sale del rol
           -- que el vendedor tenía al cargar el pedido, no del de hoy.
           public._actua_como_preventista_al(p.usuario_id, p.sucursal_id, p.created_at) AS es_preventista,
$n$, 1, '_comision_lineas: el rol al vender en ped');
  v_def := pg_temp.parche(v_def,
$a$  vend AS (
    -- COM-5 (#1321): el % de preventista es de quien actua como preventista en
    -- la sucursal del pedido (rol base o el extra), no del rol base.
    SELECT u.usuario_id, u.sucursal_id,
           _actua_como_preventista(u.usuario_id, u.sucursal_id) AS es_preventista
    FROM (SELECT DISTINCT ped.usuario_id, ped.sucursal_id FROM ped) u
  ),
$a$, '', 1, '_comision_lineas: sin vend');
  v_def := pg_temp.parche(v_def,
$a$           CASE WHEN vend.es_preventista THEN pm.pct_preventista ELSE pm.pct_otros END AS pct_default
$a$,
$n$           -- COM-5 (#1321): de quien actuaba como preventista en la sucursal del pedido.
           CASE WHEN ped.es_preventista THEN pm.pct_preventista ELSE pm.pct_otros END AS pct_default
$n$, 1, '_comision_lineas: pct_default');
  v_def := pg_temp.parche(v_def,
$a$    JOIN vend ON vend.usuario_id = ped.usuario_id AND vend.sucursal_id = ped.sucursal_id
$a$, '', 1, '_comision_lineas: sin el join a vend');
  EXECUTE v_def;
END
$comision_lineas$;

-- =========================================================================
-- 2 · COM-1, Com-B2 y Fr-B8: las reglas de comisión
-- =========================================================================
-- Com-B2: la auditoría de comision_reglas. Es la de audit_log_changes (las mismas
-- columnas de audit_logs, sólo lo que cambió), salvo una cosa: una regla para
-- todas las sucursales (sucursal_id NULL) que escribe el server, sin sucursal
-- activa, se anota con sucursal NULL. audit_log_changes la rechazaba («cannot
-- determine sucursal_id»), y el server es quien carga la regla del único admin.
CREATE FUNCTION public.audit_comision_reglas()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_old   jsonb := CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END;
  v_new   jsonb := CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END;
  v_campos text[];
  v_uid   uuid := auth.uid();
  v_email text;
  v_rol   text;
BEGIN
  IF TG_OP = 'UPDATE' THEN
    SELECT array_agg(n.key ORDER BY n.ord), jsonb_object_agg(n.key, v_old->n.key), jsonb_object_agg(n.key, n.value)
      INTO v_campos, v_old, v_new
      FROM jsonb_each(v_new) WITH ORDINALITY AS n(key, value, ord)
     WHERE v_old->n.key IS DISTINCT FROM n.value;
    IF v_campos IS NULL THEN
      RETURN NEW;
    END IF;
  END IF;
  IF v_uid IS NOT NULL THEN
    SELECT u.email INTO v_email FROM auth.users u WHERE u.id = v_uid;
    SELECT p.rol INTO v_rol FROM public.perfiles p WHERE p.id = v_uid;
  END IF;
  INSERT INTO public.audit_logs (tabla, registro_id, accion, old_data, new_data, campos_modificados,
                                 usuario_id, usuario_email, usuario_rol, sucursal_id)
  VALUES (TG_TABLE_NAME, COALESCE(NEW.id, OLD.id)::text, TG_OP, v_old, v_new, v_campos,
          v_uid, v_email, v_rol,
          COALESCE(CASE WHEN TG_OP = 'DELETE' THEN OLD.sucursal_id ELSE NEW.sucursal_id END,
                   CASE WHEN TG_OP = 'UPDATE' THEN OLD.sucursal_id END,
                   public.current_sucursal_id()));
  RETURN COALESCE(NEW, OLD);
END
$function$;
REVOKE EXECUTE ON FUNCTION public.audit_comision_reglas() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER audit_comision_reglas
  AFTER INSERT OR UPDATE OR DELETE ON public.comision_reglas
  FOR EACH ROW EXECUTE FUNCTION public.audit_comision_reglas();

-- Fr-B8: una sola regla activa por clave y día de inicio (el doble toque, y dos
-- altas a la vez).
CREATE UNIQUE INDEX comision_reglas_una_activa_por_clave ON public.comision_reglas (
  COALESCE(sucursal_id, 0),
  COALESCE(preventista_id, '00000000-0000-0000-0000-000000000000'::uuid),
  COALESCE(origen_precio::text, ''),
  COALESCE(producto_id, 0),
  COALESCE(categoria_id, '00000000-0000-0000-0000-000000000000'::uuid),
  vigente_desde
) WHERE activo;

CREATE OR REPLACE FUNCTION public.guardar_comision_regla(p_id bigint, p_sucursal_id bigint, p_preventista_id uuid, p_origen_precio text, p_porcentaje numeric, p_vigente_desde date DEFAULT NULL::date, p_vigente_hasta date DEFAULT NULL::date, p_producto_id bigint DEFAULT NULL::bigint, p_categoria_id uuid DEFAULT NULL::uuid)
 RETURNS bigint
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_id    bigint;
  v_hoy   date := _tablero_hoy();
  v_corte date := date_trunc('month', _tablero_hoy())::date;
  v_desde date;
  v_r     comision_reglas%ROWTYPE;
  v_igual comision_reglas%ROWTYPE;
BEGIN
  IF NOT es_admin() THEN
    RAISE EXCEPTION 'Solo un admin puede definir reglas de comision' USING ERRCODE = '42501';
  END IF;

  -- COM-1 (#1551, D2 del dueño del 26/11): nadie se fija su propio porcentaje,
  -- tampoco un admin. La regla de un admin la carga otro admin (o el server).
  IF p_preventista_id IS NOT NULL AND p_preventista_id = auth.uid() THEN
    RAISE EXCEPTION 'Nadie se fija su propio porcentaje de comisión: tu regla la tiene que cargar otro admin'
      USING ERRCODE = '42501';
  END IF;

  -- #1048: los admins no ven toda la red. Una regla con sucursal es de esa
  -- sucursal; una global rige en todas y sólo la toca quien las tiene todas.
  IF NOT comision_regla_alcanzable(p_sucursal_id) THEN
    RAISE EXCEPTION '%', CASE WHEN p_sucursal_id IS NULL
        THEN 'Una regla para todas las sucursales sólo la puede definir un admin asignado a todas'
        ELSE format('No tenés asignada la sucursal %s', p_sucursal_id) END
      USING ERRCODE = '42501';
  END IF;

  -- #1291: el vendedor de la regla es uno de los usuarios del admin.
  IF p_preventista_id IS NOT NULL AND NOT admin_comparte_sucursal_con(p_preventista_id) THEN
    RAISE EXCEPTION 'Ese vendedor no trabaja en ninguna de tus sucursales' USING ERRCODE = '42501';
  END IF;

  IF p_porcentaje IS NULL OR p_porcentaje < 0 OR p_porcentaje > 100 THEN
    RAISE EXCEPTION 'El porcentaje debe estar entre 0 y 100';
  END IF;

  -- #1320: los meses anteriores al mes en curso están cerrados. Ninguna regla
  -- nueva ni ninguna edición cambia lo que regía en ellos.
  IF p_id IS NULL THEN
    v_desde := COALESCE(p_vigente_desde, v_hoy);
    IF v_desde < v_corte THEN
      RAISE EXCEPTION 'Una regla no puede regir antes del %: los meses anteriores ya cerraron',
        to_char(v_corte, 'DD/MM/YYYY');
    END IF;
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
      RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
    END IF;

    -- Fr-B8: sin duplicar. El índice único de las reglas activas frena el doble
    -- toque y dos altas a la vez: la misma regla que ya rige desde ese día
    -- devuelve la que está; con otro % o hasta otro día, se rechaza.
    BEGIN
      INSERT INTO comision_reglas (
        sucursal_id, preventista_id, origen_precio, producto_id, categoria_id,
        porcentaje, vigente_desde, vigente_hasta, usuario_id
      ) VALUES (
        p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id, p_categoria_id,
        p_porcentaje, v_desde, p_vigente_hasta, auth.uid()
      )
      RETURNING id INTO v_id;
      RETURN v_id;
    EXCEPTION WHEN unique_violation THEN
      SELECT * INTO v_igual FROM comision_reglas r
       WHERE r.activo
         AND r.sucursal_id IS NOT DISTINCT FROM p_sucursal_id
         AND r.preventista_id IS NOT DISTINCT FROM p_preventista_id
         AND r.origen_precio::text IS NOT DISTINCT FROM NULLIF(p_origen_precio, '')
         AND r.producto_id IS NOT DISTINCT FROM p_producto_id
         AND r.categoria_id IS NOT DISTINCT FROM p_categoria_id
         AND r.vigente_desde = v_desde;
      IF FOUND AND v_igual.porcentaje = p_porcentaje AND v_igual.vigente_hasta IS NOT DISTINCT FROM p_vigente_hasta THEN
        RETURN v_igual.id;
      END IF;
      RAISE EXCEPTION 'Ya hay una regla igual que rige desde el % con % %%: editala o dala de baja antes de cargar otra',
        to_char(v_desde, 'DD/MM/YYYY'), replace(COALESCE(v_igual.porcentaje, 0)::text, '.', ',')
        USING ERRCODE = '23505';
    END;
  END IF;

  SELECT * INTO v_r FROM comision_reglas WHERE id = p_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'La regla % no existe', p_id USING ERRCODE = 'no_data_found';
  END IF;
  IF NOT comision_regla_alcanzable(v_r.sucursal_id) THEN
    RAISE EXCEPTION 'La regla % es de una sucursal que no tenés asignada', p_id
      USING ERRCODE = '42501';
  END IF;
  -- COM-1: tampoco se edita la propia.
  IF v_r.preventista_id IS NOT NULL AND v_r.preventista_id = auth.uid() THEN
    RAISE EXCEPTION 'Nadie se fija su propio porcentaje de comisión: tu regla la tiene que cambiar otro admin'
      USING ERRCODE = '42501';
  END IF;
  IF v_r.baja_desde IS NOT NULL THEN
    RAISE EXCEPTION 'La regla % está dada de baja: cargá una nueva', p_id;
  END IF;

  v_desde := COALESCE(p_vigente_desde, v_r.vigente_desde);

  -- Todavía no rigió en un mes cerrado: se edita entera.
  IF v_r.vigente_desde >= v_corte THEN
    IF v_desde < v_corte THEN
      RAISE EXCEPTION 'Una regla no puede regir antes del %: los meses anteriores ya cerraron',
        to_char(v_corte, 'DD/MM/YYYY');
    END IF;
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
      RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
    END IF;
    BEGIN
      UPDATE comision_reglas SET
        sucursal_id    = p_sucursal_id,
        preventista_id = p_preventista_id,
        origen_precio  = NULLIF(p_origen_precio, ''),
        producto_id    = p_producto_id,
        categoria_id   = p_categoria_id,
        porcentaje     = p_porcentaje,
        vigente_desde  = v_desde,
        vigente_hasta  = p_vigente_hasta,
        -- Com-B2: quién la cargó es quien la dejó como está.
        usuario_id     = auth.uid()
      WHERE id = p_id
      RETURNING id INTO v_id;
    EXCEPTION WHEN unique_violation THEN
      RAISE EXCEPTION 'Ya hay otra regla igual que rige desde el %: editá esa o dala de baja',
        to_char(v_desde, 'DD/MM/YYYY') USING ERRCODE = '23505';
    END;
    RETURN v_id;
  END IF;

  -- Ya rigió en un mes cerrado.
  IF v_r.vigente_hasta IS NOT NULL AND v_r.vigente_hasta < v_corte THEN
    RAISE EXCEPTION 'La regla % terminó el %: sus meses ya cerraron y no se puede cambiar',
      p_id, to_char(v_r.vigente_hasta, 'DD/MM/YYYY');
  END IF;

  IF (v_r.sucursal_id, v_r.preventista_id, v_r.origen_precio::text, v_r.producto_id,
      v_r.categoria_id, v_r.porcentaje, v_r.vigente_desde)
     IS NOT DISTINCT FROM
     (p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id,
      p_categoria_id, p_porcentaje, v_desde) THEN
    -- Sólo cambia hasta cuándo rige: se puede, mientras no termine en un mes cerrado.
    IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_corte - 1 THEN
      RAISE EXCEPTION 'La regla % no puede terminar antes del %: los meses anteriores ya cerraron',
        p_id, to_char(v_corte - 1, 'DD/MM/YYYY');
    END IF;
    UPDATE comision_reglas SET vigente_hasta = p_vigente_hasta, usuario_id = auth.uid() WHERE id = p_id;
    RETURN p_id;
  END IF;

  -- Cambia lo que rige: la regla vieja queda como estaba hasta el fin del mes
  -- anterior (dada de baja desde el 1° del mes en curso) y desde el mes en
  -- curso rige una nueva con lo pedido. Se devuelve la nueva.
  UPDATE comision_reglas
     SET vigente_hasta = v_corte - 1,
         activo        = false,
         baja_desde    = v_corte
   WHERE id = p_id;

  v_desde := GREATEST(v_desde, v_corte);
  IF p_vigente_hasta IS NOT NULL AND p_vigente_hasta < v_desde THEN
    RAISE EXCEPTION 'La regla no puede terminar antes de empezar';
  END IF;

  -- Fr-B8: sin duplicar. El índice único de las reglas activas frena el doble
  -- toque y dos altas a la vez: la misma regla que ya rige desde ese día
  -- devuelve la que está; con otro % o hasta otro día, se rechaza.
  BEGIN
    INSERT INTO comision_reglas (
      sucursal_id, preventista_id, origen_precio, producto_id, categoria_id,
      porcentaje, vigente_desde, vigente_hasta, usuario_id
    ) VALUES (
      p_sucursal_id, p_preventista_id, NULLIF(p_origen_precio, ''), p_producto_id, p_categoria_id,
      p_porcentaje, v_desde, p_vigente_hasta, auth.uid()
    )
    RETURNING id INTO v_id;
    RETURN v_id;
  EXCEPTION WHEN unique_violation THEN
    SELECT * INTO v_igual FROM comision_reglas r
     WHERE r.activo
       AND r.sucursal_id IS NOT DISTINCT FROM p_sucursal_id
       AND r.preventista_id IS NOT DISTINCT FROM p_preventista_id
       AND r.origen_precio::text IS NOT DISTINCT FROM NULLIF(p_origen_precio, '')
       AND r.producto_id IS NOT DISTINCT FROM p_producto_id
       AND r.categoria_id IS NOT DISTINCT FROM p_categoria_id
       AND r.vigente_desde = v_desde;
    IF FOUND AND v_igual.porcentaje = p_porcentaje AND v_igual.vigente_hasta IS NOT DISTINCT FROM p_vigente_hasta THEN
      RETURN v_igual.id;
    END IF;
    RAISE EXCEPTION 'Ya hay una regla igual que rige desde el % con % %%: editala o dala de baja antes de cargar otra',
      to_char(v_desde, 'DD/MM/YYYY'), replace(COALESCE(v_igual.porcentaje, 0)::text, '.', ',')
      USING ERRCODE = '23505';
  END;
END;
$function$;

DO $desactivar$
DECLARE
  v_def text := pg_get_functiondef('public.desactivar_comision_regla(bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF v_r.baja_desde IS NOT NULL THEN
    RETURN;
  END IF;
$a$,
$n$  -- COM-1 (#1551, D2): darse de baja la regla propia también es fijarse el %.
  IF v_r.preventista_id IS NOT NULL AND v_r.preventista_id = auth.uid() THEN
    RAISE EXCEPTION 'Nadie se fija su propio porcentaje de comisión: tu regla la tiene que dar de baja otro admin'
      USING ERRCODE = '42501';
  END IF;
  IF v_r.baja_desde IS NOT NULL THEN
    RETURN;
  END IF;
$n$, 1, 'desactivar_comision_regla: la propia');
  EXECUTE v_def;
END
$desactivar$;

-- La pantalla de liquidar: con qué % se calculó cada parte y quién lo cargó.
DO $liquidacion_json$
DECLARE
  v_def text := pg_get_functiondef('public._liquidacion_json(public.empleados,date,date,numeric)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$           'base', COALESCE(round(sum(l.base) FILTER (WHERE l.tipo = 'inicial'), 2), 0),
$a$,
$n$           'base', COALESCE(round(sum(l.base) FILTER (WHERE l.tipo = 'inicial'), 2), 0),
           -- COM-1 (#1551, D2): cada % con que se calculó lo pendiente, y quién lo
           -- cargó: la regla (su usuario_id) o el % por defecto del mes del
           -- pedido para su rol al vender (el de comision_pct_vigencias).
           'porcentajes', COALESCE((
             SELECT jsonb_agg(jsonb_build_object(
                      'pct', g.pct, 'regla_id', g.regla_id,
                      'origen', CASE WHEN g.regla_id IS NULL THEN 'por_defecto' ELSE 'regla' END,
                      'rol', CASE WHEN g.regla_id IS NOT NULL THEN NULL
                                  WHEN g.es_preventista THEN 'preventista' ELSE 'resto' END,
                      'cargado_por', pf.nombre,
                      'cargado_el', CASE WHEN g.regla_id IS NOT NULL
                                         THEN (r.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date
                                         ELSE (cv.actualizado_en AT TIME ZONE 'America/Argentina/Buenos_Aires')::date END,
                      'pedidos', g.pedidos, 'base', round(g.base, 2), 'comision', round(g.comision, 2))
                    ORDER BY g.base DESC, g.pct)
               FROM (SELECT i.pct, i.regla_id,
                            CASE WHEN i.regla_id IS NULL
                                 THEN public._actua_como_preventista_al(p.usuario_id, p.sucursal_id, p.created_at) END AS es_preventista,
                            CASE WHEN i.regla_id IS NULL THEN v.sucursal_id END AS vig_sucursal,
                            CASE WHEN i.regla_id IS NULL THEN v.vigente_desde END AS vig_desde,
                            count(DISTINCT i.pedido_id) AS pedidos, sum(i.base) AS base, sum(i.comision) AS comision
                       FROM l i
                       JOIN pedidos p ON p.id = i.pedido_id
                       LEFT JOIN LATERAL (
                         SELECT x.sucursal_id, x.vigente_desde FROM comision_pct_vigencias x
                          WHERE x.sucursal_id = p.sucursal_id
                            AND x.vigente_desde <= date_trunc('month', p.fecha)::date
                          ORDER BY x.vigente_desde DESC LIMIT 1) v ON i.regla_id IS NULL
                      WHERE i.tipo = 'inicial'
                      GROUP BY 1, 2, 3, 4, 5) g
               LEFT JOIN comision_reglas r ON r.id = g.regla_id
               LEFT JOIN comision_pct_vigencias cv ON cv.sucursal_id = g.vig_sucursal AND cv.vigente_desde = g.vig_desde
               LEFT JOIN perfiles pf ON pf.id = COALESCE(r.usuario_id, cv.usuario_id)), '[]'::jsonb),
$n$, 1, '_liquidacion_json: los porcentajes');
  EXECUTE v_def;
END
$liquidacion_json$;

-- =========================================================================
-- 3 · D11: el % de la simulación del gerencial, en la política comercial
-- =========================================================================
-- Constante: no reescribe la tabla. El techo deja afuera el NaN.
ALTER TABLE public.politicas_comerciales
  ADD COLUMN comision_pct_simulacion numeric(5,2) NOT NULL DEFAULT 2,
  ADD CONSTRAINT politicas_comision_pct_simulacion_rango
    CHECK (comision_pct_simulacion >= 0 AND comision_pct_simulacion <= 100);
COMMENT ON COLUMN public.politicas_comerciales.comision_pct_simulacion IS
  'D11 (reportes-R5): el % plano con que el gerencial simula la comisión. Reservado: lo da politica_comercial_reservada().';
-- Reservada: authenticated lee la tabla columna por columna y esta no se le concede.

DROP FUNCTION public.politica_comercial_reservada();
CREATE FUNCTION public.politica_comercial_reservada()
 RETURNS TABLE(comision_pct_preventista numeric, comision_pct_otros numeric, combo_margen_minimo_pct numeric, combo_descuento_maximo_pct numeric, ventana_precio_anterior_horas integer, comision_pct_simulacion numeric)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
  SELECT pc.comision_pct_preventista, pc.comision_pct_otros, pc.combo_margen_minimo_pct,
         pc.combo_descuento_maximo_pct, pc.ventana_precio_anterior_horas,
         -- D11 (reportes-R5): el % de la simulación del gerencial.
         pc.comision_pct_simulacion
    FROM public.politicas_comerciales pc
   WHERE pc.sucursal_id = public.current_sucursal_id()
     AND public.es_encargado_o_admin();
$function$;
REVOKE EXECUTE ON FUNCTION public.politica_comercial_reservada() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.politica_comercial_reservada() TO authenticated, service_role;

CREATE FUNCTION public.actualizar_comision_pct_simulacion(p_pct numeric)
RETURNS numeric
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $function$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
BEGIN
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal activa';
  END IF;
  -- D11: como los otros % de comisión, lo cambia sólo el admin.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin puede cambiar el porcentaje de la simulación de comisiones'
      USING ERRCODE = '42501';
  END IF;
  -- El techo también deja afuera el NaN.
  IF p_pct IS NULL OR NOT (p_pct >= 0 AND p_pct <= 100) THEN
    RAISE EXCEPTION 'El porcentaje de la simulación va de 0 a 100' USING ERRCODE = '22023';
  END IF;
  INSERT INTO public.politicas_comerciales (sucursal_id, comision_pct_simulacion, actualizado_por, actualizado_en)
  VALUES (v_sucursal, round(p_pct, 2), auth.uid(), now())
  ON CONFLICT (sucursal_id) DO UPDATE
    SET comision_pct_simulacion = EXCLUDED.comision_pct_simulacion,
        actualizado_por         = EXCLUDED.actualizado_por,
        actualizado_en          = EXCLUDED.actualizado_en;
  RETURN round(p_pct, 2);
END
$function$;
REVOKE EXECUTE ON FUNCTION public.actualizar_comision_pct_simulacion(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.actualizar_comision_pct_simulacion(numeric) TO authenticated, service_role;

-- El % de la simulación de un conjunto de sucursales: el que tienen todas; si
-- difieren (la Red), el de la sucursal activa; sin fila, 2.
CREATE FUNCTION public._comision_pct_simulacion(p_sucursales bigint[])
RETURNS numeric
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  WITH v AS (
    SELECT s.id, COALESCE(pc.comision_pct_simulacion, 2) AS pct
      FROM unnest(p_sucursales) AS s(id)
      LEFT JOIN public.politicas_comerciales pc ON pc.sucursal_id = s.id
  )
  SELECT CASE
           WHEN (SELECT count(DISTINCT v.pct) FROM v) = 1 THEN (SELECT min(v.pct) FROM v)
           ELSE COALESCE((SELECT v.pct FROM v WHERE v.id = public.current_sucursal_id()), 2)
         END;
$function$;
REVOKE EXECUTE ON FUNCTION public._comision_pct_simulacion(bigint[]) FROM PUBLIC, anon, authenticated;

DO $gerencial$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
    $a$'comision_pct_default', 2,$a$,
    $n$'comision_pct_default', public._comision_pct_simulacion(v_sucursales),$n$,
    1, 'reporte_gerencial: el % de la simulación');
  EXECUTE v_def;
END
$gerencial$;

-- =========================================================================
-- 4 · SEG-03 / VTA-09: el origen del precio lo calcula el server
-- =========================================================================
-- Para cada línea de un pedido, el origen que explica su precio con lo que el
-- server sabe: la lista al crearla (precio_lista_al_crear), las escalas activas
-- del pedido (las mismas reglas que precio_piso_linea: el total del grupo y
-- los productos distintos que llegan a su mínimo) y el descuento del cliente
-- (el de su categoría, o el general). NULL: la línea no se toca (combo o regalo).
CREATE FUNCTION public._origen_precio_de_lineas(p_pedido_id bigint)
RETURNS TABLE(item_id bigint, origen text, escala_id bigint)
LANGUAGE sql
STABLE
SET search_path = public, pg_temp
AS $function$
  WITH ped AS (
    SELECT p.id, p.sucursal_id, p.cliente_id FROM pedidos p WHERE p.id = p_pedido_id
  ),
  lin AS (
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.precio_unitario, pi.precio_lista_al_crear AS lista,
           pi.combo_id, COALESCE(pi.es_bonificacion, false) AS regalo, prod.categoria
      FROM pedido_items pi
      JOIN ped ON ped.id = pi.pedido_id
      LEFT JOIN productos prod ON prod.id = pi.producto_id
  ),
  -- #1191: las unidades de un combo excluyente no cuentan para ninguna escala.
  excl AS (
    SELECT c.id
      FROM combos c JOIN ped ON c.sucursal_id = ped.sucursal_id
     WHERE c.id IN (SELECT lin.combo_id FROM lin WHERE lin.combo_id IS NOT NULL)
       AND NOT COALESCE((SELECT f.combina_escalas FROM pedido_combos f
                          WHERE f.pedido_id = ped.id AND f.combo_id = c.id AND f.sucursal_id = ped.sucursal_id),
                        c.combina_escalas)
  ),
  ventas AS (
    SELECT lin.producto_id, SUM(lin.cantidad) AS cantidad
      FROM lin
     WHERE NOT lin.regalo AND lin.producto_id IS NOT NULL
       AND (lin.combo_id IS NULL OR lin.combo_id NOT IN (SELECT excl.id FROM excl))
     GROUP BY lin.producto_id
  ),
  esc AS (
    SELECT lin.id AS item_id, es.id AS escala_id,
           CASE WHEN COALESCE(mo.precio_unitario_override, 0) > 0 THEN mo.precio_unitario_override
                ELSE es.precio_unitario END AS precio
      FROM lin
      CROSS JOIN ped
      JOIN grupo_precio_productos gp ON gp.producto_id = lin.producto_id AND gp.sucursal_id = ped.sucursal_id
      JOIN grupos_precio g ON g.id = gp.grupo_precio_id AND g.sucursal_id = ped.sucursal_id AND COALESCE(g.activo, true)
      JOIN grupo_precio_escalas es ON es.grupo_precio_id = g.id AND COALESCE(es.activo, true)
      LEFT JOIN LATERAL (
        SELECT m.precio_unitario_override FROM grupo_precio_escala_minimos m
         WHERE m.escala_id = es.id AND m.producto_id = lin.producto_id
         ORDER BY m.id LIMIT 1) mo ON true
     WHERE lin.combo_id IS NULL AND NOT lin.regalo
       -- regla 1: el total del grupo llega al mínimo de la escala.
       AND (SELECT COALESCE(SUM(v.cantidad), 0) FROM ventas v
             WHERE v.producto_id IN (SELECT g2.producto_id FROM grupo_precio_productos g2
                                      WHERE g2.grupo_precio_id = g.id AND g2.sucursal_id = ped.sucursal_id))
           >= COALESCE(es.cantidad_minima, 0)
       -- regla 3: los productos distintos que llegan a su mínimo por producto.
       AND (SELECT count(*) FROM ventas v
             WHERE v.producto_id IN (SELECT g2.producto_id FROM grupo_precio_productos g2
                                      WHERE g2.grupo_precio_id = g.id AND g2.sucursal_id = ped.sucursal_id)
               AND v.cantidad > 0
               AND v.cantidad >= COALESCE((SELECT m.cantidad_minima_por_item FROM grupo_precio_escala_minimos m
                                            WHERE m.escala_id = es.id AND m.producto_id = v.producto_id
                                            ORDER BY m.id LIMIT 1), 0))
           >= GREATEST(1, COALESCE(es.min_productos_distintos, 1))
  ),
  mejor AS (
    SELECT DISTINCT ON (esc.item_id) esc.item_id, esc.escala_id, esc.precio
      FROM esc WHERE esc.precio > 0
     ORDER BY esc.item_id, esc.precio, esc.escala_id
  ),
  dto AS (
    SELECT lin.id AS item_id, cat.pct AS pct_cat, COALESCE(cl.descuento_porcentaje, 0) AS pct_gral
      FROM lin
      CROSS JOIN ped
      LEFT JOIN clientes cl ON cl.id = ped.cliente_id AND cl.sucursal_id = ped.sucursal_id
      LEFT JOIN LATERAL (
        SELECT COALESCE(d.descuento_porcentaje, 0) AS pct FROM cliente_descuentos_categoria d
         WHERE d.cliente_id = ped.cliente_id
           AND NULLIF(lin.categoria, '') IS NOT NULL
           AND upper(trim(COALESCE(d.categoria, ''))) = upper(trim(lin.categoria))
         ORDER BY d.id LIMIT 1) cat ON true
  ),
  calc AS (
    SELECT lin.*, mj.escala_id AS mj_escala, mj.precio AS mj_precio,
           COALESCE(dto.pct_cat, dto.pct_gral) AS pct, dto.pct_cat IS NOT NULL AS de_categoria
      FROM lin
      LEFT JOIN mejor mj ON mj.item_id = lin.id
      LEFT JOIN dto ON dto.item_id = lin.id
  ),
  et AS (
    SELECT c.id,
           CASE
             WHEN c.combo_id IS NOT NULL OR c.regalo THEN NULL
             WHEN c.lista IS NULL OR c.lista <= 0 THEN 'desconocido'
             WHEN c.mj_precio < c.lista
                  AND (c.precio_unitario = c.mj_precio
                       OR (c.pct > 0 AND c.precio_unitario = round(c.mj_precio * (1 - c.pct / 100), 2)))
               THEN 'mayorista'
             WHEN c.pct > 0 AND c.precio_unitario = round(c.lista * (1 - c.pct / 100), 2)
               THEN CASE WHEN c.de_categoria THEN 'desc_categoria' ELSE 'desc_cliente' END
             WHEN c.precio_unitario = c.lista THEN 'lista'
             ELSE 'manual'
           END AS origen,
           c.mj_escala
      FROM calc c
  )
  SELECT et.id, et.origen, CASE WHEN et.origen = 'mayorista' THEN et.mj_escala END
    FROM et;
$function$;
REVOKE EXECUTE ON FUNCTION public._origen_precio_de_lineas(bigint) FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.registrar_origen_precio_items(p_pedido_id bigint, p_origenes jsonb, p_perfil_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
  v_uid          uuid := auth.uid();
  v_caller       uuid;
  v_dueno        uuid;
  v_sucursal     bigint;
  v_actualizados integer := 0;
BEGIN
  SELECT usuario_id, sucursal_id INTO v_dueno, v_sucursal
  FROM pedidos WHERE id = p_pedido_id;

  IF v_dueno IS NULL AND v_sucursal IS NULL THEN
    RAISE EXCEPTION 'Pedido % inexistente', p_pedido_id USING ERRCODE = 'no_data_found';
  END IF;

  -- #1329: con sesion manda la sesion. p_perfil_id es del server (el bot), y el
  -- pedido tiene que ser de la sucursal activa.
  IF v_uid IS NOT NULL AND (p_perfil_id <> auth.uid()
                            OR v_sucursal IS DISTINCT FROM current_sucursal_id()) THEN
    RAISE EXCEPTION 'Sin permiso para registrar el origen del precio de este pedido'
      USING ERRCODE = '42501';
  END IF;

  v_caller := COALESCE(v_uid, p_perfil_id);

  IF NOT (es_encargado_o_admin() OR (v_caller IS NOT NULL AND v_caller = v_dueno)) THEN
    RAISE EXCEPTION 'Sin permiso para registrar el origen del precio de este pedido'
      USING ERRCODE = '42501';
  END IF;

  -- SEG-03 / VTA-09 (decisión del dueño del 27/11): el origen de cada línea lo
  -- calcula el server (_origen_precio_de_lineas); lo que manda el teléfono
  -- (p_origenes) se ignora, y queda en la firma por los bundles viejos. Sólo
  -- las líneas que el alta dejó sin determinar (las de lista, regalo y combo ya
  -- las etiquetó completar_origen_precio_item). La escala de una línea
  -- mayorista también la pone el server.
  UPDATE pedido_items pi
     SET origen_precio          = o.origen,
         grupo_precio_escala_id = CASE WHEN o.origen = 'mayorista' THEN o.escala_id
                                       ELSE pi.grupo_precio_escala_id END
    FROM public._origen_precio_de_lineas(p_pedido_id) o
   WHERE pi.id = o.item_id
     AND pi.pedido_id = p_pedido_id
     AND (pi.origen_precio IS NULL OR pi.origen_precio = 'desconocido')
     AND o.origen IS NOT NULL
     AND o.origen IS DISTINCT FROM pi.origen_precio;
  GET DIAGNOSTICS v_actualizados = ROW_COUNT;

  RETURN jsonb_build_object('success', true, 'actualizados', v_actualizados);
END;
$function$;

-- =========================================================================
-- 5, 6 · Com-B7 y Com-B8: las metas
-- =========================================================================
CREATE OR REPLACE FUNCTION public._metas_logrado(p_meta_ids bigint[])
 RETURNS TABLE(meta_id bigint, logrado numeric)
 LANGUAGE sql
 STABLE
 SET search_path TO 'public', 'pg_temp'
AS $function$
  WITH m AS MATERIALIZED (
    SELECT * FROM metas_preventista WHERE id = ANY(p_meta_ids)
  ),
  rango AS (
    SELECT m.preventista_id, m.sucursal_id, min(m.periodo) AS desde, max(m.periodo_fin) AS hasta
      FROM m
     GROUP BY m.preventista_id, m.sucursal_id
  ),
  ped AS MATERIALIZED (
    SELECT p.id, p.cliente_id, p.usuario_id, p.sucursal_id, p.fecha, p.total,
           -- Com-B7 (decisión del dueño del 27/11): lo cobrado con adelanto de
           -- sueldo es una venta a un empleado y no suma para las metas, como no
           -- comisiona (_comision_lineas): todos sus adelantos.
           COALESCE(ad.monto, 0) AS adelanto
      FROM rango r
      JOIN pedidos p ON p.usuario_id = r.preventista_id AND p.sucursal_id = r.sucursal_id
                    AND p.fecha BETWEEN r.desde AND r.hasta
      LEFT JOIN LATERAL (
        SELECT SUM(g.monto) AS monto FROM pagos g
         WHERE g.pedido_id = p.id AND g.forma_pago = 'adelanto_sueldo'
      ) ad ON true
     WHERE p.estado = 'entregado'
       AND p.canal <> 'cambio'
       -- 3XB: el vale blanco no cuenta para ninguna meta.
       AND p.tipo_factura IS DISTINCT FROM 'VB'
  ),
  -- Los renglones de cada boleta por su índice, boleta por boleta (LATERAL con
  -- OFFSET 0): sin estadísticas, el planner estimaba `ped` en una fila y
  -- recorría todos los renglones contra todas las boletas (N2 de la revisión de
  -- la v4: crear una nota tardaba de 8 a 27 s con 8.000 boletas).
  it AS MATERIALIZED (
    SELECT ped.id AS pedido_id, ped.usuario_id, ped.sucursal_id, ped.fecha, pi.cantidad, pi.subtotal,
           pi.producto_id, prod.categoria_id, prod.marca_id
      FROM ped
      CROSS JOIN LATERAL (
        SELECT x.cantidad, x.subtotal, x.producto_id
          FROM pedido_items x
         WHERE x.pedido_id = ped.id AND x.es_bonificacion IS NOT TRUE
        OFFSET 0
      ) pi
      -- #1262: LEFT. La línea de un producto borrado suma a las metas globales.
      LEFT JOIN productos prod ON prod.id = pi.producto_id
  ),
  -- La boleta de la nota se busca por id, nota por nota, y se le piden las
  -- condiciones de ped con el período de la meta: el LIMIT hace que el planner
  -- no la cruce antes con las metas ni la busque por otro índice. Sin
  -- estadísticas, cruzar las boletas del vendedor con las metas antes de las
  -- notas multiplicaba las filas (31 s con 500 notas).
  ncm AS MATERIALIZED (
    SELECT nm.meta_id, n.pedido_id, CASE WHEN mot.descuenta_unidades THEN -i.cantidad ELSE 0 END AS cantidad,
           -i.subtotal AS subtotal, i.producto_id, prod.categoria_id, prod.marca_id
      FROM nota_credito_venta_metas nm
      JOIN m ON m.id = nm.meta_id
      JOIN notas_credito_venta n ON n.id = nm.nota_credito_id
      CROSS JOIN LATERAL (
        SELECT p.usuario_id, p.sucursal_id, p.fecha, p.estado, p.canal, p.tipo_factura
          FROM pedidos p WHERE p.id = n.pedido_id LIMIT 1
      ) bol
      JOIN nota_credito_venta_items i ON i.nota_credito_id = n.id
      JOIN public.nc_venta_motivos() mot ON mot.motivo = n.motivo
      LEFT JOIN productos prod ON prod.id = i.producto_id
     WHERE bol.usuario_id = m.preventista_id AND bol.sucursal_id = m.sucursal_id
       AND bol.fecha BETWEEN m.periodo AND m.periodo_fin
       AND bol.estado = 'entregado' AND bol.canal <> 'cambio'
       AND bol.tipo_factura IS DISTINCT FROM 'VB'
  ),
  -- Com-B7: el factor de cada boleta en cada meta es el de _comision_lineas: la
  -- parte que no se pagó con adelanto, sobre la venta neta de las notas que
  -- restan de esa meta (boleta de 1.000 con 400 de adelanto: 0,6). Sin
  -- adelanto, 1.
  fac AS (
    SELECT m.id AS meta_id, ped.id AS pedido_id,
           CASE WHEN ped.adelanto <= 0 THEN 1
                WHEN ped.total - COALESCE(nc.monto, 0) > 0
                THEN 1 - LEAST(ped.adelanto, ped.total - COALESCE(nc.monto, 0)) / (ped.total - COALESCE(nc.monto, 0))
                ELSE 1 END AS factor
      FROM m
      JOIN ped ON ped.usuario_id = m.preventista_id AND ped.sucursal_id = m.sucursal_id
              AND ped.fecha BETWEEN m.periodo AND m.periodo_fin
      LEFT JOIN (SELECT ncm.meta_id, ncm.pedido_id, -SUM(ncm.subtotal) AS monto
                   FROM ncm GROUP BY ncm.meta_id, ncm.pedido_id) nc
             ON nc.meta_id = m.id AND nc.pedido_id = ped.id
     WHERE m.tipo_meta IN ('facturacion', 'unidades')
       AND ped.adelanto > 0
  ),
  filas AS (
    SELECT m.id AS meta_id, it.cantidad * COALESCE(f.factor, 1) AS cantidad, it.subtotal * COALESCE(f.factor, 1) AS subtotal
      FROM m
      JOIN it ON it.usuario_id = m.preventista_id AND it.sucursal_id = m.sucursal_id
             AND it.fecha BETWEEN m.periodo AND m.periodo_fin
      LEFT JOIN fac f ON f.meta_id = m.id AND f.pedido_id = it.pedido_id
     WHERE m.tipo_meta IN ('facturacion', 'unidades')
       AND (m.marca_id     IS NULL OR it.marca_id     = m.marca_id)
       AND (m.categoria_id IS NULL OR it.categoria_id = m.categoria_id)
       AND (m.producto_ids IS NULL OR it.producto_id  = ANY(m.producto_ids))
    UNION ALL
    SELECT m.id, ncm.cantidad * COALESCE(f.factor, 1), ncm.subtotal * COALESCE(f.factor, 1)
      FROM m
      JOIN ncm ON ncm.meta_id = m.id
      LEFT JOIN fac f ON f.meta_id = m.id AND f.pedido_id = ncm.pedido_id
     WHERE m.tipo_meta IN ('facturacion', 'unidades')
       AND (m.marca_id     IS NULL OR ncm.marca_id     = m.marca_id)
       AND (m.categoria_id IS NULL OR ncm.categoria_id = m.categoria_id)
       AND (m.producto_ids IS NULL OR ncm.producto_id  = ANY(m.producto_ids))
  ),
  suma AS (
    SELECT filas.meta_id, SUM(filas.cantidad) AS cantidad, SUM(filas.subtotal) AS monto
      FROM filas GROUP BY filas.meta_id
  ),
  cob AS (
    SELECT m.id AS meta_id, COUNT(DISTINCT ped.cliente_id) AS n
      FROM m
      JOIN ped ON ped.usuario_id = m.preventista_id AND ped.sucursal_id = m.sucursal_id
              AND ped.fecha BETWEEN m.periodo AND m.periodo_fin
     WHERE m.tipo_meta = 'cobertura'
       -- Com-B8 (decisión del dueño del 27/11): cuenta el cliente con una venta
       -- de verdad, la que deja algo vendido que no se pagó con adelanto de
       -- sueldo (Com-B7). Un pedido de $ 0 (sólo regalo o sólo canje: 0 no es
       -- mayor que 0) o pagado entero con adelanto no lo hace atendido. (El envío
       -- solo no existe: sin productos el pedido no lleva envío, VENTA-A.)
       AND ped.total > ped.adelanto
     GROUP BY m.id
  ),
  primer AS (
    SELECT DISTINCT ON (p.cliente_id, p.sucursal_id) p.cliente_id, p.sucursal_id, p.usuario_id, p.fecha
      FROM pedidos p
     WHERE p.estado = 'entregado' AND p.canal <> 'cambio'
       AND p.tipo_factura IS DISTINCT FROM 'VB'  -- 3XB: un vale no hace cliente nuevo
       AND p.sucursal_id IN (SELECT m.sucursal_id FROM m WHERE m.tipo_meta = 'clientes_nuevos')
     ORDER BY p.cliente_id, p.sucursal_id, p.fecha, p.id
  ),
  nuevos AS (
    SELECT m.id AS meta_id, COUNT(*) AS n
      FROM m
      JOIN primer pp ON pp.sucursal_id = m.sucursal_id AND pp.usuario_id = m.preventista_id
                    AND pp.fecha BETWEEN m.periodo AND m.periodo_fin
     WHERE m.tipo_meta = 'clientes_nuevos'
     GROUP BY m.id
  )
  SELECT m.id,
         (CASE m.tipo_meta
            WHEN 'facturacion'     THEN COALESCE(s.monto, 0)
            WHEN 'unidades'        THEN COALESCE(s.cantidad, 0)
            WHEN 'cobertura'       THEN COALESCE(c.n, 0)
            WHEN 'clientes_nuevos' THEN COALESCE(nu.n, 0)
          END)::numeric
    FROM m
    LEFT JOIN suma s    ON s.meta_id = m.id
    LEFT JOIN cob c     ON c.meta_id = m.id
    LEFT JOIN nuevos nu ON nu.meta_id = m.id;
$function$;

-- =========================================================================
-- 7 · REP-7: calcular_comisiones sin sucursales, la Red
-- =========================================================================
DO $calcular$
DECLARE
  v_def text := pg_get_functiondef('public.calcular_comisiones(date,date,bigint[])'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    v_sucursales := p_sucursal_ids;
  END IF;
$a$,
$n$    v_sucursales := p_sucursal_ids;
  ELSE
    -- REP-7 (#1522): sin sucursales, la Red: las activas asignadas
    -- (_sucursales_red), como los reportes. Las asignadas siguen siendo el
    -- límite de lo que se puede pedir.
    v_sucursales := COALESCE(public._sucursales_red(), '{}'::bigint[]);
  END IF;
$n$, 1, 'calcular_comisiones: la Red');
  EXECUTE v_def;
END
$calcular$;

-- =========================================================================
-- 8 · Com-B6 (1562-b5): las metas propias piden un rol activo
-- =========================================================================
DO $avance$
DECLARE
  v_def text := pg_get_functiondef('public.avance_metas_preventista(uuid,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
$a$,
$n$  -- Com-B6 (1562-b5): quien llama actúa como preventista o es admin, y está
  -- activo (un desactivado no tiene ningún rol, #1474: los dos helpers dan false).
  IF auth.uid() IS NOT NULL AND NOT (public.es_preventista() OR public.es_admin()) THEN
    RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
  END IF;

  IF auth.uid() IS NOT NULL AND v_target <> auth.uid() AND NOT es_admin() THEN
$n$, 1, 'avance_metas_preventista: el rol de quien llama');
  EXECUTE v_def;
END
$avance$;

DROP POLICY metas_preventista_propio_select ON public.metas_preventista;
-- Com-B6 (1562-b5): sus metas las ve quien actúa como preventista y está activo.
CREATE POLICY metas_preventista_propio_select ON public.metas_preventista
  FOR SELECT TO authenticated
  USING (preventista_id = (SELECT auth.uid()) AND (SELECT public.es_preventista()));

-- ---------------------------------------------------------------------------
-- Poscondiciones
-- ---------------------------------------------------------------------------
DO $pos$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public._comision_lineas(bigint[])', 'b93a3efb555bfebf862d1b5c808c9900'),
    ('public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)', 'f7feabef61bac55296da4ba8624407b6'),
    ('public.desactivar_comision_regla(bigint)', '098efc23c0d9277f15d75e7cd731ad3c'),
    ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', 'b3f3f55a1ba883f8db7efd7179ab76fd'),
    ('public.calcular_comisiones(date,date,bigint[])', 'f38d4a50d825aed08e982c20069af5b2'),
    ('public.avance_metas_preventista(uuid,date)', '052db709ffdeb14d3b8c3b36d5277ec7'),
    ('public._metas_logrado(bigint[])', '5bbbcb203407063cc218d669e2782be3'),
    ('public.politica_comercial_reservada()', '01091e1286a85ff0cb8e7b2500023a24'),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)', '4eb740b658a3703a670beefc4f3c3d7f'),
    ('public._liquidacion_json(public.empleados,date,date,numeric)', '78006e434678e176f0559545caad5e53'),
    ('public._rol_al_momento(uuid,timestamptz)', '6d88a66fbc6248ee0044f1435ec6d50b'),
    ('public._actua_como_preventista_al(uuid,bigint,timestamptz)', 'b732b8a4a9e7d7410816592f6f3598de'),
    ('public.perfiles_anota_cambio_de_rol()', 'c79627f67259228cfbac0856fe6906b5'),
    ('public.actualizar_comision_pct_simulacion(numeric)', '23512b0ed973914e4914e7d53c8573b6'),
    ('public._comision_pct_simulacion(bigint[])', '25e49e4876fbf757d6ace1edf7f2c1a8'),
    ('public._origen_precio_de_lineas(bigint)', 'ed1fbb78df7281a21d4785ce458968ab'),
    ('public.audit_comision_reglas()', 'a1a70817ef721cb37e1b32ee8d9cd557')
  ) AS t(f, h) LOOP
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como se esperaba (md5 %)', r.f, v;
    END IF;
  END LOOP;
  -- search_path terminado en pg_temp; grants: las RPC de authenticated (sin
  -- anon) y las de server sin ninguno de los tres.
  FOR r IN SELECT * FROM (VALUES
    ('public.guardar_comision_regla(bigint,bigint,uuid,text,numeric,date,date,bigint,uuid)', true),
    ('public.desactivar_comision_regla(bigint)', true),
    ('public.registrar_origen_precio_items(bigint,jsonb,uuid)', true),
    ('public.calcular_comisiones(date,date,bigint[])', true),
    ('public.avance_metas_preventista(uuid,date)', true),
    ('public.politica_comercial_reservada()', true),
    ('public.actualizar_comision_pct_simulacion(numeric)', true),
    ('public._rol_al_momento(uuid,timestamptz)', false),
    ('public._actua_como_preventista_al(uuid,bigint,timestamptz)', false),
    ('public.perfiles_anota_cambio_de_rol()', false),
    ('public._comision_pct_simulacion(bigint[])', false),
    ('public._origen_precio_de_lineas(bigint)', false),
    ('public.audit_comision_reglas()', false)
  ) AS t(f, rpc) LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc p, unnest(p.proconfig) c
                    WHERE p.oid = r.f::regprocedure AND c LIKE 'search_path=%pg_temp') THEN
      RAISE EXCEPTION 'mig NNN · % sin search_path terminado en pg_temp', r.f;
    END IF;
    IF has_function_privilege('anon', r.f, 'EXECUTE')
       OR has_function_privilege('authenticated', r.f, 'EXECUTE') IS DISTINCT FROM r.rpc THEN
      RAISE EXCEPTION 'mig NNN · % con grants inesperados', r.f;
    END IF;
  END LOOP;
  IF has_table_privilege('authenticated', 'public.perfil_rol_cambios', 'SELECT')
     OR has_table_privilege('anon', 'public.perfil_rol_cambios', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · perfil_rol_cambios quedó legible por REST';
  END IF;
  IF has_column_privilege('authenticated', 'public.politicas_comerciales', 'comision_pct_simulacion', 'SELECT')
     OR has_column_privilege('anon', 'public.politicas_comerciales', 'comision_pct_simulacion', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · comision_pct_simulacion quedó legible por REST (es reservada)';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.comision_reglas'::regclass
                  AND tgname = 'audit_comision_reglas' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'mig NNN · comision_reglas sin auditoría';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.perfiles'::regclass
                  AND tgname = 'trg_perfiles_anota_cambio_de_rol' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'mig NNN · perfiles sin el historial de rol';
  END IF;
  IF EXISTS (SELECT 1 FROM public.politicas_comerciales WHERE comision_pct_simulacion IS DISTINCT FROM 2) THEN
    RAISE EXCEPTION 'mig NNN · la semilla del %% de la simulación no es 2';
  END IF;
END
$pos$;

COMMIT;
