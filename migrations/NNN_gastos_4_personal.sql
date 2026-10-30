-- =========================================================================
-- NNN · GASTOS 4 · PERSONAL: EL EMPLEADO, SU ARREGLO Y SU CUENTA (entrega 3 de 5)
--
-- Diseno: docs/superpowers/specs/2026-10-28-gastos-y-cuentas-del-personal-design.md
-- Plan:   docs/superpowers/plans/2026-10-29-gastos-3-personal.md (Tarea 2)
-- Ensayo: scripts/test-gastos-4.sql
--
-- El empleado existe en la app, con usuario o sin el, con su arreglo (sueldo,
-- frecuencia y si comisiona, con fecha de vigencia) y su cuenta. La cuenta es
-- un libro con signo: positivo, la empresa le debe; negativo, el le debe a la
-- empresa. El saldo es la suma, en vivo. Nada se edita ni se borra: un
-- movimiento a mano se revierte con otro que apunta a el (revierte_id).
--
-- QUE AGREGA
--   * empleados, empleado_arreglos y empleado_movimientos.
--   * gastos.empleado_id: "Un empleado" como origen del pago, que _guardar_gasto
--     rechazaba hasta aca.
--   * rubro.pide_litros_km en obtener_gastos_rendiciones: sin eso, el cierre no
--     sabe si un rubro dado de baja pide litros y km, y GAS-1 quedaba abierto
--     en ese camino. _guardar_gasto y esta son las dos funciones vivas que se
--     reescriben.
--   * Dos triggers que asientan solos los movimientos automaticos:
--     - la mercaderia, desde un pago con adelanto de sueldo sobre la ficha de
--       cliente de un empleado (pagos_cuenta_empleado);
--     - el reintegro, desde un gasto pagado por un empleado con su plata
--       (gastos_cuenta_empleado).
--   * Las RPCs de Personal: listar_personal, obtener_cuenta_empleado,
--     empleados_para_elegir, cliente_admite_adelanto_sueldo, guardar_empleado,
--     guardar_arreglo_empleado, dar_de_baja_empleado, reactivar_empleado,
--     registrar_movimiento_empleado y revertir_movimiento_empleado.
--   * GAS-1 de #1322: en una edicion, litros y km_tablero que no vienen en el
--     JSON quedan como estaban; un null explicito los borra.
--
-- LAS TABLAS SON DE SERVER, como pedido_promo_reglas: RLS sin policies y nada
-- para authenticated ni anon. Se leen y se escriben solo por las RPCs DEFINER,
-- y quien ve a quien lo dice _empleado_visible. Asi un sueldo no sale nunca por
-- REST, y no hay embeds nuevos que probar. scripts/grants-rest.json no cambia.
--
-- COMO CONCILIA UN TRIGGER. En pagos y en gastos, el trigger AFTER calcula
-- cuanto tendria que haber en la cuenta por esa fila (el objetivo), lo compara
-- con lo que ya hay y asienta la diferencia (_cuenta_empleado_conciliar). Es la
-- misma cuenta para un alta, un cambio de monto, un pedazo, un cambio de
-- cliente o de empleado, una anulacion o un borrado, asi que cubre todos los
-- caminos que escriben pagos sin tocar ninguna funcion de cobro: las dos FIFO,
-- las que parten un pago, desafectar_sobrepago_pedido, cambiar_cliente_pedido
-- y el DELETE REST de eliminarPago, el unico que queda: desde cobros_4,
-- authenticated no tiene INSERT ni UPDATE sobre pagos.
-- El rechazo del adelanto sin vinculo va en el mismo trigger, y no en
-- registrar_pagos_pedido(_impl) ni en _forma_pago_de_cobro (tarjeta 2 de #1306).
--
-- SIN CORTE POR ID. Un pago entra al libro si es el alta de una raiz con
-- adelanto de sueldo (o pasa a serlo), o si el o su familia (pago_raiz_id) ya
-- tienen movimientos. Los 8 historicos (5242 a 7777), sus pedazos y todo lo
-- cargado antes de esta migracion no tienen movimientos y no entran nunca: ya
-- se descontaron fuera de la app. Un corte por id dejaria entrar a los pedazos
-- nuevos de un pago viejo (nacen con id nuevo), que es justo lo que no tiene
-- que pasar.
--
-- EL EMPLEADO DE UN PEDAZO es el que ya tiene la familia en el cliente del
-- pedazo (la foto pago_raiz_id + cliente_id de cada movimiento), no el de la
-- raiz: cambiar_cliente_pedido mueve un pedazo a otro cliente y
-- _pagos_excedente_a_favor lo parte ahi mismo.
--
-- LIMITE CONOCIDO de "nadie se paga a si mismo": el trigger rechaza el DELETE
-- REST (eliminarPago) de un adelanto de la ficha propia, pero no una salvedad,
-- una edicion o un cambio de cliente sobre un pedido propio, que tambien bajan
-- o mueven el pago por una RPC: es el #1354.
--
-- PERMISOS: RPCs del front con REVOKE PUBLIC, anon y GRANT authenticated;
-- helpers de server con REVOKE PUBLIC, anon, authenticated; las funciones de
-- trigger sin EXECUTE para nadie (las invoca el executor como parte del DML).
--
-- DESPLIEGUE: no cambia firmas que use el bundle viejo. Desde que se aplica, el
-- adelanto de sueldo se RECHAZA en todo cliente que no sea la ficha de un
-- empleado activo (decision 8 del plan): hoy son el 376 y el 9. Vuelve cuando
-- el duenio da de alta a esos empleados y vincula sus fichas desde Personal.
-- =========================================================================

SET LOCAL lock_timeout = '5s';

-- -------------------------------------------------------------------------
-- 0 · Las funciones que se reescriben enteras son las de hoy
-- -------------------------------------------------------------------------
-- Molde de la 413: md5(prosrc) de prod al escribir esto (2026-10-29), que es
-- byte a byte el cuerpo de la 413. Si otra migracion las cambio en el medio,
-- esta las pisaria sin avisar: se aborta y se rehace sobre la definicion viva.
DO $vivas$
DECLARE
  r record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public._guardar_gasto(jsonb,boolean)', '6056ce94ba972040a968111cb02af2f8'),
      ('public.obtener_gastos_rendiciones(date,date,uuid)', 'ea970259104287b5a93b540b6b277ef2')) AS v(firma, md5)
  LOOP
    IF to_regprocedure(r.firma) IS NULL
       OR (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-10-29: rehacer la migracion sobre la definicion viva', r.firma;
    END IF;
  END LOOP;
END
$vivas$;

-- -------------------------------------------------------------------------
-- 1 · Las tablas
-- -------------------------------------------------------------------------
-- Las FKs a clientes y vehiculos son simples, no compuestas: un empleado "de
-- las dos" se vincula a un cliente de cualquier sucursal. La regla la valida
-- guardar_empleado.
CREATE TABLE public.empleados (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  sucursal_id   bigint NOT NULL REFERENCES public.sucursales(id),
  de_las_dos    boolean NOT NULL DEFAULT false,
  nombre        text NOT NULL CHECK (btrim(nombre) <> ''),
  puesto        text NOT NULL CHECK (puesto IN ('preventista', 'transportista', 'ayudante', 'deposito',
                                                'administracion', 'encargado', 'otro')),
  cuil          text CHECK (cuil ~ '^[0-9]{11}$'),
  fecha_ingreso date,
  telefono      text,
  usuario_id    uuid UNIQUE REFERENCES public.perfiles(id),
  cliente_id    bigint UNIQUE REFERENCES public.clientes(id),
  vehiculo_id   bigint REFERENCES public.vehiculos(id),
  activo        boolean NOT NULL DEFAULT true,
  fecha_baja    date,
  creado_por    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT empleados_baja_check CHECK (activo = (fecha_baja IS NULL))
);

COMMENT ON TABLE public.empleados IS
  'El personal, con usuario de la app o sin el (gastos 4). sucursal_id es donde se cargo; de_las_dos lo ven solo los admins de todas. Tabla de server: se lee y se escribe solo por las RPCs de Personal.';

CREATE TABLE public.empleado_arreglos (
  id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id   bigint NOT NULL REFERENCES public.empleados(id),
  vigente_desde date NOT NULL,
  sueldo        numeric(12,2) NOT NULL CHECK (sueldo >= 0),
  frecuencia    text NOT NULL CHECK (frecuencia IN ('semanal', 'mensual')),
  comisiona     boolean NOT NULL,
  creado_por    uuid NOT NULL,
  created_at    timestamptz NOT NULL DEFAULT now(),
  updated_at    timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT empleado_arreglos_sueldo_o_comision CHECK (sueldo > 0 OR comisiona),
  CONSTRAINT empleado_arreglos_empleado_desde_key UNIQUE (empleado_id, vigente_desde)
);

COMMENT ON TABLE public.empleado_arreglos IS
  'El arreglo de cada empleado: sueldo fijo, frecuencia y si comisiona, desde una fecha. Vale hasta el dia antes del siguiente. Uno nuevo vale desde despues del ultimo; con la misma fecha lo corrige; no se borran (gastos 4). Tabla de server.';

-- pago_id, pago_raiz_id, cliente_id y pedido_id sin FK: el pago se puede
-- borrar y el movimiento queda. pago_raiz_id (COALESCE(pago_origen_id, id)),
-- cliente_id y pedido_id son la foto del pago al asentar. cliente_id es la
-- ficha por la que el empleado tiene ese pago: el pedazo nuevo de una familia
-- va al empleado que ya tiene la familia en el cliente del pedazo, no al de la
-- raiz, que pudo cambiar de cliente.
CREATE TABLE public.empleado_movimientos (
  id           bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  empleado_id  bigint NOT NULL REFERENCES public.empleados(id),
  fecha        date NOT NULL,
  tipo         text NOT NULL CHECK (tipo IN ('mercaderia', 'reintegro', 'adelanto', 'ajuste')),
  monto        numeric(14,2) NOT NULL CHECK (monto <> 0),
  observacion  text,
  pago_id      bigint,
  pago_raiz_id bigint,
  cliente_id   bigint,
  pedido_id    bigint,
  gasto_id     bigint REFERENCES public.gastos(id),
  revierte_id  bigint UNIQUE REFERENCES public.empleado_movimientos(id),
  creado_por   uuid,
  created_at   timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT empleado_movimientos_mercaderia_pago CHECK ((tipo = 'mercaderia') = (pago_id IS NOT NULL)),
  CONSTRAINT empleado_movimientos_mercaderia_foto CHECK ((tipo = 'mercaderia') = (pago_raiz_id IS NOT NULL)
                                                        AND (tipo = 'mercaderia') = (cliente_id IS NOT NULL)),
  CONSTRAINT empleado_movimientos_reintegro_gasto CHECK ((tipo = 'reintegro') = (gasto_id IS NOT NULL)),
  CONSTRAINT empleado_movimientos_revierte_a_mano CHECK (revierte_id IS NULL OR tipo IN ('adelanto', 'ajuste')),
  CONSTRAINT empleado_movimientos_adelanto_negativo CHECK (tipo <> 'adelanto' OR revierte_id IS NOT NULL OR monto < 0),
  CONSTRAINT empleado_movimientos_ajuste_con_obs CHECK (tipo <> 'ajuste' OR observacion IS NOT NULL)
);

CREATE INDEX empleado_movimientos_cuenta_idx ON public.empleado_movimientos (empleado_id, fecha, id);
CREATE INDEX empleado_movimientos_pago_idx ON public.empleado_movimientos (pago_id) WHERE pago_id IS NOT NULL;
CREATE INDEX empleado_movimientos_raiz_idx ON public.empleado_movimientos (pago_raiz_id, cliente_id)
  WHERE pago_raiz_id IS NOT NULL;
CREATE INDEX empleado_movimientos_gasto_idx ON public.empleado_movimientos (gasto_id) WHERE gasto_id IS NOT NULL;

COMMENT ON TABLE public.empleado_movimientos IS
  'La cuenta del empleado: un libro con signo (+ la empresa le debe, - el le debe). La mercaderia y el reintegro los asientan los triggers de pagos y gastos; el adelanto en efectivo y el ajuste, a mano. Nada se edita ni se borra (gastos 4). Tabla de server.';

ALTER TABLE public.empleados ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empleado_arreglos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.empleado_movimientos ENABLE ROW LEVEL SECURITY;

-- Tambien el SELECT: sin policies, una tabla legible quedaria roja en
-- select_sin_policy. Sin GRANT de secuencias: nadie inserta por REST.
REVOKE ALL ON TABLE public.empleados, public.empleado_arreglos, public.empleado_movimientos
  FROM PUBLIC, anon, authenticated;

CREATE TRIGGER audit_empleados
  AFTER INSERT OR UPDATE OR DELETE ON public.empleados
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();
CREATE TRIGGER audit_empleado_arreglos
  AFTER INSERT OR UPDATE OR DELETE ON public.empleado_arreglos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- -------------------------------------------------------------------------
-- 2 · El empleado que pago un gasto
-- -------------------------------------------------------------------------
-- Entra por el GRANT SELECT de tabla de la 411: el front lo lee con el gasto.
ALTER TABLE public.gastos
  ADD COLUMN empleado_id bigint REFERENCES public.empleados(id),
  ADD CONSTRAINT gastos_empleado_check CHECK ((origen_pago = 'empleado') = (empleado_id IS NOT NULL));

CREATE INDEX gastos_empleado_idx ON public.gastos (empleado_id) WHERE origen_pago = 'empleado';

COMMENT ON COLUMN public.gastos.empleado_id IS
  'Con origen_pago = empleado: el empleado que lo pago con su plata. Le queda a favor como reintegro en su cuenta (gastos 4).';
COMMENT ON COLUMN public.gastos.origen_pago IS
  'oficina | rendicion | empleado. Rendicion desde gastos 3 (con rendicion_transportista_id y rendicion_fecha); empleado desde gastos 4 (con empleado_id).';

-- -------------------------------------------------------------------------
-- 3 · Helpers de server
-- -------------------------------------------------------------------------
-- Quien ve a quien: solo un admin; uno de las dos, solo el admin de todas; el
-- resto, el de la sucursal en la que esta.
CREATE FUNCTION public._empleado_visible(p_sucursal_id bigint, p_de_las_dos boolean)
RETURNS boolean
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT COALESCE(public.es_admin()
                  AND CASE WHEN p_de_las_dos THEN public._tiene_todas_las_sucursales()
                           ELSE p_sucursal_id = public.current_sucursal_id() END, false);
$fn$;

-- La forma de Empleado (src/types/personal.ts). El arreglo es el vigente hoy,
-- o el primero si ninguno empezo.
CREATE FUNCTION public._empleado_json(p_e public.empleados)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
    'id', p_e.id, 'nombre', p_e.nombre, 'puesto', p_e.puesto, 'sucursal_id', p_e.sucursal_id,
    'de_las_dos', p_e.de_las_dos, 'cuil', p_e.cuil, 'fecha_ingreso', p_e.fecha_ingreso, 'telefono', p_e.telefono,
    'activo', p_e.activo, 'fecha_baja', p_e.fecha_baja,
    'usuario', (SELECT jsonb_build_object('id', pf.id, 'nombre', pf.nombre) FROM perfiles pf WHERE pf.id = p_e.usuario_id),
    'cliente', (SELECT jsonb_build_object('id', c.id, 'nombre_fantasia', COALESCE(c.nombre_fantasia, c.razon_social),
                                          'activo', COALESCE(c.activo, true))
                  FROM clientes c WHERE c.id = p_e.cliente_id),
    'vehiculo', (SELECT jsonb_build_object('id', v.id, 'patente', v.patente, 'descripcion', v.descripcion)
                   FROM vehiculos v WHERE v.id = p_e.vehiculo_id),
    'arreglo', (SELECT jsonb_build_object(
                         'id', a.id, 'vigente_desde', a.vigente_desde,
                         'vigente_hasta', (SELECT min(b.vigente_desde) - 1 FROM empleado_arreglos b
                                            WHERE b.empleado_id = a.empleado_id AND b.vigente_desde > a.vigente_desde),
                         'sueldo', a.sueldo, 'frecuencia', a.frecuencia, 'comisiona', a.comisiona)
                  FROM empleado_arreglos a
                 WHERE a.empleado_id = p_e.id
                 ORDER BY (a.vigente_desde <= public._tablero_hoy()) DESC,
                          CASE WHEN a.vigente_desde <= public._tablero_hoy() THEN a.vigente_desde END DESC NULLS LAST,
                          a.vigente_desde
                 LIMIT 1),
    'arranque', (SELECT min(a.vigente_desde) FROM empleado_arreglos a WHERE a.empleado_id = p_e.id),
    'saldo', COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m WHERE m.empleado_id = p_e.id), 0),
    'es_propio', COALESCE(p_e.usuario_id = auth.uid(), false));
$fn$;

-- Lleva la cuenta de una fuente (un pago o un gasto) a su objetivo: p_objetivo
-- para p_empleado_id y 0 para cualquier otro que tenga movimientos de esa
-- fuente. Asienta solo las diferencias. El primer movimiento de la fuente va
-- con su fecha y sin observacion; los que lo corrigen, con la de hoy y el
-- motivo. Los otros empleados van antes, asi el ultimo movimiento de la fuente
-- es siempre el del empleado que la tiene ahora. En la mercaderia, el
-- movimiento del empleado que la tiene lleva el cliente de hoy del pago
-- (p_cliente_id); el que compensa a otro, el cliente por el que ese otro la
-- tenia.
CREATE FUNCTION public._cuenta_empleado_conciliar(
  p_tipo        text,
  p_pago_id     bigint,
  p_pago_raiz_id bigint,
  p_cliente_id  bigint,
  p_gasto_id    bigint,
  p_empleado_id bigint,
  p_objetivo    numeric,
  p_fecha       date,
  p_pedido_id   bigint,
  p_motivo      text
)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_habia boolean;
  v_dif   numeric;
  r       record;
BEGIN
  IF p_tipo IS NULL OR p_tipo NOT IN ('mercaderia', 'reintegro') THEN
    RAISE EXCEPTION '_cuenta_empleado_conciliar: tipo %', p_tipo;
  END IF;
  v_habia := EXISTS (SELECT 1 FROM empleado_movimientos m
                      WHERE (p_tipo = 'mercaderia' AND m.pago_id = p_pago_id)
                         OR (p_tipo = 'reintegro' AND m.gasto_id = p_gasto_id));
  FOR r IN
    SELECT x.empleado_id,
           COALESCE((SELECT sum(m.monto) FROM empleado_movimientos m
                      WHERE m.empleado_id = x.empleado_id
                        AND ((p_tipo = 'mercaderia' AND m.pago_id = p_pago_id)
                             OR (p_tipo = 'reintegro' AND m.gasto_id = p_gasto_id))), 0) AS suma
      FROM (SELECT m.empleado_id FROM empleado_movimientos m
             WHERE (p_tipo = 'mercaderia' AND m.pago_id = p_pago_id)
                OR (p_tipo = 'reintegro' AND m.gasto_id = p_gasto_id)
            UNION
            SELECT p_empleado_id WHERE p_empleado_id IS NOT NULL) x
     ORDER BY (x.empleado_id = p_empleado_id) NULLS FIRST, x.empleado_id
  LOOP
    v_dif := round(CASE WHEN r.empleado_id = p_empleado_id THEN COALESCE(p_objetivo, 0) ELSE 0 END - r.suma, 2);
    IF v_dif <> 0 THEN
      INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, pago_id, pago_raiz_id, cliente_id,
                                        pedido_id, gasto_id, creado_por)
      VALUES (r.empleado_id,
              CASE WHEN v_habia THEN public._tablero_hoy() ELSE p_fecha END,
              p_tipo, v_dif,
              CASE WHEN v_habia THEN p_motivo END,
              CASE WHEN p_tipo = 'mercaderia' THEN p_pago_id END,
              CASE WHEN p_tipo = 'mercaderia' THEN p_pago_raiz_id END,
              CASE WHEN p_tipo <> 'mercaderia' THEN NULL
                   WHEN r.empleado_id = p_empleado_id THEN p_cliente_id
                   ELSE (SELECT m.cliente_id FROM empleado_movimientos m
                          WHERE m.empleado_id = r.empleado_id AND m.pago_id = p_pago_id
                          ORDER BY m.id DESC LIMIT 1) END,
              CASE WHEN p_tipo = 'mercaderia' THEN p_pedido_id END,
              CASE WHEN p_tipo = 'reintegro' THEN p_gasto_id END,
              auth.uid());
    END IF;
  END LOOP;
END
$fn$;

-- -------------------------------------------------------------------------
-- 4 · Los movimientos automaticos
-- -------------------------------------------------------------------------
-- La mercaderia sigue al pago con adelanto de sueldo. Ver la cabecera.
--
-- Sin advisory lock por familia: tomado despues del lock de fila armaba un
-- ciclo contra desafectar_sobrepago_pedido (UPDATE uno por uno) e
-- imputar_credito_a_pedido_impl (la fila FOR UPDATE). No hace falta: lo de
-- cada pago (pago_id) solo lo cambian los triggers de esa misma fila, que su
-- lock de fila ya serializa; y el empleado de un pedazo nuevo sale de la foto
-- (pago_raiz_id, cliente_id), que no depende del orden entre pedazos.
CREATE FUNCTION public.pagos_cuenta_empleado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_fila       pagos%ROWTYPE;
  v_raiz       bigint;
  v_propios    boolean;
  v_de_raiz    boolean;
  v_entra      boolean;
  v_cambio_cli boolean := false;
  v_cambio_frm boolean := false;
  v_adelanto   boolean;
  v_emp        bigint;
  v_activo     boolean;
  v_objetivo   numeric;
  v_motivo     text;
BEGIN
  -- Solo puede haber algo que asentar si el pago es o era un adelanto: si no,
  -- el objetivo es 0 antes y despues.
  IF TG_OP = 'DELETE' THEN
    v_fila := OLD;
    IF OLD.forma_pago IS DISTINCT FROM 'adelanto_sueldo' THEN
      RETURN NULL;
    END IF;
  ELSE
    v_fila := NEW;
    IF NEW.forma_pago IS DISTINCT FROM 'adelanto_sueldo' THEN
      IF TG_OP = 'INSERT' THEN
        RETURN NULL;
      END IF;
      IF OLD.forma_pago IS DISTINCT FROM 'adelanto_sueldo' THEN
        RETURN NULL;
      END IF;
    END IF;
  END IF;
  IF TG_OP = 'UPDATE' THEN
    v_cambio_cli := OLD.cliente_id IS DISTINCT FROM NEW.cliente_id;
    v_cambio_frm := OLD.forma_pago IS DISTINCT FROM NEW.forma_pago;
  END IF;
  v_adelanto := TG_OP <> 'DELETE' AND v_fila.forma_pago = 'adelanto_sueldo';
  v_raiz := COALESCE(v_fila.pago_origen_id, v_fila.id);

  -- 1 · Entra al libro?
  v_propios := EXISTS (SELECT 1 FROM empleado_movimientos WHERE pago_id = v_fila.id);
  v_de_raiz := EXISTS (SELECT 1 FROM empleado_movimientos WHERE pago_raiz_id = v_raiz);
  v_entra := v_propios OR v_de_raiz
             OR (TG_OP = 'INSERT' AND v_fila.pago_origen_id IS NULL)
             -- Un pago que pasa a ser adelanto (no lo hace ninguna RPC de hoy).
             OR (v_cambio_frm AND v_adelanto);
  IF NOT v_entra THEN
    RETURN NULL;
  END IF;

  -- 2 · El empleado.
  IF v_propios AND NOT v_cambio_cli THEN
    -- (a) El que ya tiene el pago por este cliente: asi no lo mueve un cambio
    --     posterior del vinculo. Si no hay, el de saldo distinto de 0, o el
    --     del ultimo movimiento.
    SELECT m.empleado_id INTO v_emp
      FROM empleado_movimientos m
     WHERE m.pago_id = v_fila.id
     GROUP BY m.empleado_id
     ORDER BY bool_or(m.cliente_id = v_fila.cliente_id) DESC, (sum(m.monto) <> 0) DESC, max(m.id) DESC
     LIMIT 1;
  ELSIF NOT v_propios AND v_fila.pago_origen_id IS NOT NULL AND TG_OP <> 'DELETE' THEN
    -- (b) Un pedazo nuevo: el que ya tiene la familia en el cliente del
    --     pedazo (un pedazo puede nacer en otro cliente que la raiz, y la raiz
    --     cambiar de cliente), o si no, el vinculado hoy a ese cliente.
    --     Primero sobre los pagos VIVOS de la familia en ese cliente: el
    --     empleado cuyo neto en ellos no es 0. Los movimientos solos no
    --     alcanzan: la compensacion de un pedazo que se fue del cliente lleva
    --     el cliente del empleado anterior, y puede ser el ultimo. Si no queda
    --     ninguno vivo (desafectar_sobrepago_pedido borra antes de insertar el
    --     pedazo), la foto de los movimientos.
    SELECT m.empleado_id INTO v_emp
      FROM pagos p
      JOIN empleado_movimientos m ON m.pago_id = p.id
     WHERE (p.id = v_raiz OR p.pago_origen_id = v_raiz)
       AND p.id <> NEW.id AND p.cliente_id = NEW.cliente_id
     GROUP BY m.empleado_id
    HAVING sum(m.monto) <> 0
     ORDER BY max(m.id) DESC
     LIMIT 1;
    IF v_emp IS NULL THEN
      SELECT m.empleado_id INTO v_emp
        FROM empleado_movimientos m
       WHERE m.pago_raiz_id = v_raiz AND m.cliente_id = NEW.cliente_id
       ORDER BY m.id DESC
       LIMIT 1;
    END IF;
    IF v_emp IS NULL THEN
      SELECT e.id INTO v_emp FROM empleados e WHERE e.cliente_id = NEW.cliente_id;
    END IF;
    IF v_emp IS NULL AND v_adelanto THEN
      RAISE EXCEPTION 'El adelanto de sueldo es sólo para la ficha de cliente de un empleado: vinculala desde Personal o elegí otra forma de pago';
    END IF;
  ELSIF TG_OP <> 'DELETE' THEN
    -- (c) Una raiz nueva o un cliente cambiado: el de la ficha.
    SELECT e.id, e.activo INTO v_emp, v_activo FROM empleados e WHERE e.cliente_id = NEW.cliente_id;
    IF v_adelanto THEN
      IF v_emp IS NULL AND v_cambio_cli THEN
        RAISE EXCEPTION 'Este pago es un adelanto de sueldo y el cliente nuevo no es la ficha de un empleado: anulá el pago antes de cambiar el cliente';
      ELSIF v_emp IS NULL THEN
        RAISE EXCEPTION 'El adelanto de sueldo es sólo para la ficha de cliente de un empleado: vinculala desde Personal o elegí otra forma de pago';
      ELSIF NOT v_activo THEN
        RAISE EXCEPTION 'Ese cliente es la ficha de un empleado dado de baja: ya no se le dan adelantos de sueldo';
      END IF;
    END IF;
  END IF;

  -- 3 · Nadie se paga a si mismo (decision 3): el DELETE REST de eliminarPago
  --     sobre un adelanto de la ficha propia le subiria la cuenta. Las RPCs
  --     que borran un pago corren con request.path /rpc/.
  IF TG_OP = 'DELETE' AND COALESCE(current_setting('request.method', true), '') = 'DELETE'
     AND COALESCE(current_setting('request.path', true), '') NOT LIKE '/rpc/%'
     AND EXISTS (SELECT 1 FROM empleados WHERE id = v_emp AND usuario_id = auth.uid()) THEN
    RAISE EXCEPTION 'Un adelanto de sueldo de tu propia ficha lo anula otro admin';
  END IF;

  -- 4 · El objetivo y el motivo
  v_objetivo := CASE WHEN v_adelanto THEN -v_fila.monto ELSE 0 END;
  v_motivo := CASE WHEN TG_OP = 'DELETE' THEN 'Se borró el pago'
                   WHEN v_cambio_cli THEN 'El pago pasó a otro cliente'
                   WHEN v_cambio_frm THEN 'El pago cambió de forma de pago'
                   ELSE 'El pago cambió de monto' END;

  -- 5 · Concilia
  PERFORM public._cuenta_empleado_conciliar('mercaderia', v_fila.id, v_raiz, v_fila.cliente_id, NULL, v_emp,
                                            v_objetivo, v_fila.fecha, v_fila.pedido_id, v_motivo);
  RETURN NULL;
END
$fn$;

CREATE TRIGGER trg_pagos_cuenta_empleado
  AFTER INSERT OR DELETE OR UPDATE OF monto, cliente_id, forma_pago, pago_origen_id ON public.pagos
  FOR EACH ROW EXECUTE FUNCTION public.pagos_cuenta_empleado();

-- El reintegro sigue al gasto pagado por un empleado. La fila del gasto ya
-- esta bloqueada por el propio DML: no hace falta otro lock.
CREATE FUNCTION public.gastos_cuenta_empleado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_objetivo numeric;
  v_emp      bigint;
  v_motivo   text;
BEGIN
  IF NEW.origen_pago IS DISTINCT FROM 'empleado' THEN
    IF TG_OP = 'INSERT' THEN
      RETURN NULL;
    END IF;
    IF OLD.origen_pago IS DISTINCT FROM 'empleado' THEN
      RETURN NULL;
    END IF;
  END IF;
  v_emp := CASE WHEN NEW.origen_pago = 'empleado' THEN NEW.empleado_id END;
  v_objetivo := CASE WHEN NEW.origen_pago = 'empleado' AND NEW.anulado_at IS NULL THEN NEW.monto_total ELSE 0 END;
  IF TG_OP = 'UPDATE' THEN
    v_motivo := CASE WHEN NEW.anulado_at IS NOT NULL AND OLD.anulado_at IS NULL THEN 'Se anuló el gasto'
                     WHEN OLD.origen_pago = 'empleado' AND NEW.origen_pago <> 'empleado'
                       THEN 'El gasto dejó de estar pagado por un empleado'
                     WHEN OLD.empleado_id IS DISTINCT FROM NEW.empleado_id THEN 'El gasto pasó a otro empleado'
                     ELSE 'El gasto cambió de monto' END;
  END IF;
  PERFORM public._cuenta_empleado_conciliar('reintegro', NULL, NULL, NULL, NEW.id, v_emp, v_objetivo, NEW.fecha,
                                            NULL, v_motivo);
  RETURN NULL;
END
$fn$;

CREATE TRIGGER trg_gastos_cuenta_empleado
  AFTER INSERT OR UPDATE OF monto_total, origen_pago, empleado_id, anulado_at ON public.gastos
  FOR EACH ROW EXECUTE FUNCTION public.gastos_cuenta_empleado();

-- -------------------------------------------------------------------------
-- 5 · _guardar_gasto: el cuerpo de la 413, con "Un empleado" y GAS-1
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._guardar_gasto(p_gasto jsonb, p_desde_cierre boolean)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid       uuid := auth.uid();
  v_admin     boolean := public.es_admin();
  v_actual    bigint := public.current_sucursal_id();
  v_id        bigint;
  v_viejo     gastos%ROWTYPE;
  v_releido   gastos%ROWTYPE;
  v_rubro     gasto_rubros%ROWTYPE;
  v_empleado  empleados%ROWTYPE;
  v_suc       bigint;
  v_comp      boolean;
  v_fecha     date;
  v_rubro_id  bigint;
  v_total     numeric;
  v_tipo      text;
  v_numero    text;
  v_alicuota  numeric;
  v_iva       numeric;
  v_piva      numeric;
  v_piibb     numeric;
  v_otros     numeric;
  v_veh       bigint;
  v_litros    numeric;
  v_km        integer;
  v_mes       date;
  v_meses     integer;
  v_origen    text;
  v_obs       text;
  v_rend_tr   uuid;
  v_rend_f    date;
  v_emp       bigint;
BEGIN
  -- 1 · rol
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado pueden cargar gastos';
  END IF;
  IF jsonb_typeof(p_gasto) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos del gasto';
  END IF;
  BEGIN
    v_id       := NULLIF(p_gasto->>'id', '')::bigint;
    v_suc      := COALESCE(NULLIF(p_gasto->>'sucursal_id', '')::bigint, v_actual);
    v_comp     := COALESCE((p_gasto->>'compartido')::boolean, false);
    v_fecha    := NULLIF(p_gasto->>'fecha', '')::date;
    v_rubro_id := NULLIF(p_gasto->>'rubro_id', '')::bigint;
    v_total    := round(NULLIF(p_gasto->>'monto_total', '')::numeric, 2);
    v_tipo     := NULLIF(btrim(p_gasto->>'comprobante'), '');
    v_numero   := NULLIF(btrim(p_gasto->>'comprobante_numero'), '');
    v_alicuota := NULLIF(p_gasto->>'alicuota_iva', '')::numeric;
    v_iva      := round(COALESCE(NULLIF(p_gasto->>'iva', '')::numeric, 0), 2);
    v_piva     := round(COALESCE(NULLIF(p_gasto->>'percepcion_iva', '')::numeric, 0), 2);
    v_piibb    := round(COALESCE(NULLIF(p_gasto->>'percepcion_iibb', '')::numeric, 0), 2);
    v_otros    := round(COALESCE(NULLIF(p_gasto->>'otros_impuestos', '')::numeric, 0), 2);
    v_veh      := NULLIF(p_gasto->>'vehiculo_id', '')::bigint;
    v_litros   := round(NULLIF(p_gasto->>'litros', '')::numeric, 2);
    v_km       := NULLIF(p_gasto->>'km_tablero', '')::integer;
    v_mes      := NULLIF(p_gasto->>'mes_imputado', '')::date;
    v_meses    := COALESCE(NULLIF(p_gasto->>'repartir_meses', '')::integer, 1);
    v_origen   := COALESCE(NULLIF(btrim(p_gasto->>'origen_pago'), ''), 'oficina');
    v_obs      := NULLIF(btrim(p_gasto->>'observacion'), '');
    v_rend_tr  := NULLIF(btrim(p_gasto->>'rendicion_transportista_id'), '')::uuid;
    v_rend_f   := NULLIF(p_gasto->>'rendicion_fecha', '')::date;
    v_emp      := NULLIF(p_gasto->>'empleado_id', '')::bigint;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END;
  -- En numeric, NaN es MAYOR que todo: pasaria un > 0.
  IF 'NaN'::numeric IN (v_total, v_iva, v_piva, v_piibb, v_otros, v_alicuota, v_litros) THEN
    RAISE EXCEPTION 'Hay un dato del gasto con un formato inválido';
  END IF;

  -- 2 · sucursal
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No se pudo determinar la sucursal del gasto: elegí una sucursal';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us JOIN sucursales s ON s.id = us.sucursal_id
                  WHERE us.usuario_id = v_uid AND us.sucursal_id = v_suc AND s.activa) THEN
    RAISE EXCEPTION 'No tenés asignada esa sucursal: el gasto va en una de tus sucursales';
  END IF;

  -- 3 · lo que el encargado no puede
  IF NOT v_admin THEN
    IF v_comp THEN
      RAISE EXCEPTION 'Sólo un admin puede cargar un gasto compartido';
    END IF;
    IF v_suc IS DISTINCT FROM v_actual THEN
      RAISE EXCEPTION 'El encargado carga gastos sólo en la sucursal en la que está';
    END IF;
  END IF;

  IF v_id IS NOT NULL THEN
    -- Desde el cierre, confirmar_rendicion ya bloqueo la rendicion: la fila
    -- va FOR UPDATE ya. Desde Gastos, primero la rendicion (paso 8b).
    IF p_desde_cierre THEN
      SELECT * INTO v_viejo FROM gastos WHERE id = v_id FOR UPDATE;
    ELSE
      SELECT * INTO v_viejo FROM gastos WHERE id = v_id;
    END IF;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese gasto no existe';
    END IF;
    -- Antes que el vehiculo: si no, cambiar de sucursal un gasto con vehiculo
    -- daria "el vehiculo no es de la sucursal", que no dice que hacer.
    IF v_viejo.sucursal_id <> v_suc THEN
      RAISE EXCEPTION 'Un gasto no cambia de sucursal: anulalo y cargalo de nuevo en la otra';
    END IF;
  END IF;

  -- 4 · rubro (uno dado de baja se puede conservar al editar, no elegir)
  SELECT * INTO v_rubro FROM gasto_rubros WHERE id = v_rubro_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Elegí el rubro del gasto';
  END IF;
  IF NOT v_rubro.activo AND v_viejo.rubro_id IS DISTINCT FROM v_rubro_id THEN
    RAISE EXCEPTION 'El rubro % está dado de baja: elegí otro', v_rubro.nombre;
  END IF;

  -- 5 · vehiculo (idem)
  IF v_veh IS NOT NULL AND NOT EXISTS (
       SELECT 1 FROM vehiculos
        WHERE id = v_veh AND sucursal_id = v_suc
          AND (activo OR v_viejo.vehiculo_id IS NOT DISTINCT FROM v_veh)) THEN
    RAISE EXCEPTION 'El vehículo no es de la sucursal del gasto o está dado de baja';
  END IF;

  -- 5b · GAS-1 (#1322, gastos 4): en una edicion, litros y km_tablero que no
  --     vienen en el JSON quedan como estaban (un null explicito los borra).
  --     El modal manda esas claves solo si el rubro las pide, y con un rubro
  --     dado de baja no lo sabia. La lectura de km conservada sigue al vehiculo
  --     y a la fecha del gasto. Con un rubro que no los pide, se van.
  IF v_id IS NOT NULL AND v_rubro.pide_litros_km THEN
    IF NOT p_gasto ? 'litros' THEN
      v_litros := v_viejo.litros;
    END IF;
    IF NOT p_gasto ? 'km_tablero' AND v_veh IS NOT NULL THEN
      SELECT km INTO v_km FROM vehiculo_km WHERE gasto_id = v_id;
    END IF;
  END IF;

  -- 6 · litros y km del tablero, solo con un rubro que los pide
  IF (v_litros IS NOT NULL OR v_km IS NOT NULL) AND NOT v_rubro.pide_litros_km THEN
    RAISE EXCEPTION 'Este rubro no lleva litros ni km';
  END IF;
  IF v_litros IS NOT NULL AND v_litros <= 0 THEN
    RAISE EXCEPTION 'Los litros tienen que ser más que cero';
  END IF;
  IF v_km IS NOT NULL AND v_veh IS NULL THEN
    RAISE EXCEPTION 'Para anotar los km del tablero elegí el vehículo';
  END IF;
  IF v_km IS NOT NULL AND v_km NOT BETWEEN 0 AND 9999999 THEN
    RAISE EXCEPTION 'Los km del tablero tienen que estar entre 0 y 9.999.999';
  END IF;

  -- 7 · datos y desglose (los mensajes de errorDeDesglose, src/utils/gastos.ts)
  IF v_fecha IS NULL THEN
    RAISE EXCEPTION 'Falta la fecha del gasto';
  END IF;
  IF v_total IS NULL OR v_total <= 0 OR v_total > 999999999999.99 THEN
    RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
  END IF;
  IF v_tipo IS NULL OR v_tipo NOT IN ('factura_a', 'factura_m', 'factura_b', 'factura_c', 'recibo', 'ticket', 'ninguno') THEN
    RAISE EXCEPTION 'Elegí el comprobante del gasto';
  END IF;
  IF v_iva < 0 OR v_piva < 0 OR v_piibb < 0 OR v_otros < 0 THEN
    RAISE EXCEPTION 'Ningún importe puede ser negativo';
  END IF;
  IF v_tipo IN ('factura_a', 'factura_m') THEN
    IF v_total - v_iva - v_piva - v_piibb - v_otros <= 0 THEN
      RAISE EXCEPTION 'Con factura A o M el neto tiene que ser mayor a cero';
    END IF;
    IF v_alicuota IS NOT NULL AND v_alicuota NOT IN (21, 10.5, 27) THEN
      RAISE EXCEPTION 'La alícuota de IVA tiene que ser 21, 10,5 o 27';
    END IF;
  ELSE
    IF v_iva > 0 OR v_piva > 0 OR v_piibb > 0 OR v_otros > 0 THEN
      RAISE EXCEPTION 'Sólo la factura A o M lleva IVA y percepciones';
    END IF;
    -- Sin desglose, la alicuota no significa nada.
    v_alicuota := NULL;
  END IF;
  IF v_meses NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'Un gasto se reparte en 1 a 120 meses';
  END IF;
  v_mes := date_trunc('month', COALESCE(v_mes, v_fecha)::timestamp)::date;

  -- 8 · origen: la oficina, una rendicion o un empleado
  IF v_origen = 'oficina' THEN
    v_rend_tr := NULL;
    v_rend_f  := NULL;
    v_emp     := NULL;
  ELSIF v_origen = 'rendicion' THEN
    v_emp := NULL;
    IF v_rend_tr IS NULL OR v_rend_f IS NULL THEN
      RAISE EXCEPTION 'Elegí de qué rendición salió la plata: el transportista y el día';
    END IF;
    IF v_rend_f > public._tablero_hoy() THEN
      RAISE EXCEPTION 'La rendición no puede ser de un día que todavía no llegó';
    END IF;
    -- Un gasto que ya era de esta rendicion se sigue pudiendo cambiar aunque el
    -- chofer ya no tenga la sucursal: si no, "Editar cierre" no podria tocar
    -- sus rendiciones viejas. Uno nuevo, o que llega a esta rendicion, si la pide.
    IF NOT (v_id IS NOT NULL AND v_viejo.origen_pago = 'rendicion'
            AND v_viejo.rendicion_transportista_id = v_rend_tr AND v_viejo.rendicion_fecha = v_rend_f)
       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_rend_tr AND sucursal_id = v_suc) THEN
      RAISE EXCEPTION 'Ese transportista no es de la sucursal del gasto';
    END IF;
  ELSIF v_origen = 'empleado' THEN
    -- gastos 4: le queda a favor como reintegro (trg_gastos_cuenta_empleado).
    v_rend_tr := NULL;
    v_rend_f  := NULL;
    IF v_emp IS NULL THEN
      RAISE EXCEPTION 'Elegí qué empleado pagó el gasto';
    END IF;
    SELECT * INTO v_empleado FROM empleados WHERE id = v_emp;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
    END IF;
    -- Uno que cambio de sucursal o se dio de baja se conserva al editar, no se elige.
    IF v_empleado.sucursal_id <> v_suc AND NOT v_empleado.de_las_dos
       AND v_viejo.empleado_id IS DISTINCT FROM v_emp THEN
      RAISE EXCEPTION 'Ese empleado no es de la sucursal del gasto';
    END IF;
    IF NOT v_empleado.activo AND v_viejo.empleado_id IS DISTINCT FROM v_emp THEN
      RAISE EXCEPTION 'Ese empleado está dado de baja';
    END IF;
    IF v_empleado.usuario_id = v_uid THEN
      RAISE EXCEPTION 'Un gasto que pagaste vos lo carga otro admin o el encargado';
    END IF;
  ELSE
    RAISE EXCEPTION 'Elegí con qué plata se pagó el gasto';
  END IF;

  -- 8b · desde Gastos: la rendicion vieja y la nueva, y recien ahi la fila
  IF NOT p_desde_cierre THEN
    PERFORM public._rendicion_bloquear(ARRAY[
      CASE WHEN v_viejo.origen_pago = 'rendicion'
           THEN public._rendicion_clave(v_viejo.rendicion_transportista_id, v_viejo.rendicion_fecha, v_viejo.sucursal_id)
      END,
      public._rendicion_clave(v_rend_tr, v_rend_f, v_suc)]);
    IF v_id IS NOT NULL THEN
      SELECT * INTO v_releido FROM gastos WHERE id = v_id FOR UPDATE;
      -- Si otro lo movio de rendicion entre las dos lecturas, el lock que
      -- tenemos no es el de su rendicion de ahora. Ni el empleado que lo
      -- pago, que el paso 8 ya miro (gastos 4).
      IF v_releido.origen_pago IS DISTINCT FROM v_viejo.origen_pago
         OR v_releido.rendicion_transportista_id IS DISTINCT FROM v_viejo.rendicion_transportista_id
         OR v_releido.rendicion_fecha IS DISTINCT FROM v_viejo.rendicion_fecha
         OR v_releido.empleado_id IS DISTINCT FROM v_viejo.empleado_id THEN
        RAISE EXCEPTION 'El gasto cambió mientras lo guardabas: volvé a intentarlo';
      END IF;
      v_viejo := v_releido;
    END IF;
  END IF;

  -- 8c · nadie se paga a si mismo (decision 3): tampoco cambia, en ningun
  --      sentido, un gasto que pago el. Sobre la fila ya bloqueada.
  IF v_viejo.origen_pago = 'empleado'
     AND EXISTS (SELECT 1 FROM empleados WHERE id = v_viejo.empleado_id AND usuario_id = v_uid) THEN
    RAISE EXCEPTION 'Un gasto que pagaste vos lo carga otro admin o el encargado';
  END IF;

  -- 9 · edicion: quien lo puede cambiar
  IF v_id IS NOT NULL THEN
    IF v_viejo.anulado_at IS NOT NULL THEN
      RAISE EXCEPTION 'Este gasto está anulado: no se puede cambiar';
    END IF;
    IF v_admin THEN
      IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_uid AND sucursal_id = v_viejo.sucursal_id) THEN
        RAISE EXCEPTION 'No tenés asignada la sucursal de este gasto';
      END IF;
      IF v_viejo.compartido AND v_viejo.creado_por IS DISTINCT FROM v_uid
         AND NOT public._tiene_todas_las_sucursales() THEN
        RAISE EXCEPTION 'Este gasto compartido lo puede cambiar quien lo cargó o un admin de todas las sucursales';
      END IF;
      -- Compartirlo se lo saca al que lo cargo (el encargado deja de verlo, y
      -- desde ahi solo lo toca un admin de todas): lo decide el o uno de todas.
      IF v_comp AND NOT v_viejo.compartido AND v_viejo.creado_por IS DISTINCT FROM v_uid
         AND NOT public._tiene_todas_las_sucursales() THEN
        RAISE EXCEPTION 'Para compartir un gasto que cargó otro, anulalo y cargalo de nuevo como compartido';
      END IF;
    ELSIF v_viejo.creado_por IS DISTINCT FROM v_uid OR v_viejo.compartido THEN
      RAISE EXCEPTION 'El encargado sólo edita los gastos que cargó';
    END IF;
  END IF;

  -- 10 · desde Gastos, una rendicion cerrada no se toca: es "Editar cierre"
  IF NOT p_desde_cierre THEN
    IF v_viejo.origen_pago = 'rendicion'
       AND public.control_rendicion_cerrado(v_viejo.rendicion_transportista_id, v_viejo.sucursal_id, v_viejo.rendicion_fecha) THEN
      RAISE EXCEPTION 'Este gasto es de una rendición cerrada: se cambia desde «Editar cierre» en Rendiciones';
    END IF;
    IF v_origen = 'rendicion' AND public.control_rendicion_cerrado(v_rend_tr, v_suc, v_rend_f) THEN
      RAISE EXCEPTION 'Esa rendición ya está cerrada: el gasto se carga desde «Editar cierre» en Rendiciones';
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO gastos (sucursal_id, compartido, fecha, rubro_id, monto_total, comprobante, comprobante_numero,
                        alicuota_iva, iva, percepcion_iva, percepcion_iibb, otros_impuestos, vehiculo_id, litros,
                        mes_imputado, repartir_meses, origen_pago, rendicion_transportista_id, rendicion_fecha,
                        empleado_id, observacion, creado_por)
    VALUES (v_suc, v_comp, v_fecha, v_rubro_id, v_total, v_tipo, v_numero,
            v_alicuota, v_iva, v_piva, v_piibb, v_otros, v_veh, v_litros,
            v_mes, v_meses, v_origen, v_rend_tr, v_rend_f,
            v_emp, v_obs, v_uid)
    RETURNING id INTO v_id;
  ELSE
    UPDATE gastos
       SET compartido = v_comp, fecha = v_fecha, rubro_id = v_rubro_id, monto_total = v_total,
           comprobante = v_tipo, comprobante_numero = v_numero, alicuota_iva = v_alicuota, iva = v_iva,
           percepcion_iva = v_piva, percepcion_iibb = v_piibb, otros_impuestos = v_otros,
           vehiculo_id = v_veh, litros = v_litros, mes_imputado = v_mes, repartir_meses = v_meses,
           origen_pago = v_origen, rendicion_transportista_id = v_rend_tr, rendicion_fecha = v_rend_f,
           empleado_id = v_emp, observacion = v_obs, updated_at = now()
     WHERE id = v_id;
  END IF;

  -- La lectura de km de la carga es la del gasto: la crea, la corrige o la borra.
  IF v_km IS NOT NULL THEN
    INSERT INTO vehiculo_km (sucursal_id, vehiculo_id, fecha, km, origen, gasto_id, creado_por)
    VALUES (v_suc, v_veh, v_fecha, v_km, 'carga', v_id, v_uid)
    ON CONFLICT (gasto_id) DO UPDATE
      SET vehiculo_id = EXCLUDED.vehiculo_id, fecha = EXCLUDED.fecha, km = EXCLUDED.km;
  ELSE
    DELETE FROM vehiculo_km WHERE gasto_id = v_id;
  END IF;

  RETURN v_id;
END
$fn$;

-- -------------------------------------------------------------------------
-- 5b · obtener_gastos_rendiciones: la de la 413, con rubro.pide_litros_km
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.obtener_gastos_rendiciones(p_fecha_desde date, p_fecha_hasta date, p_transportista_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_sucursal_id BIGINT;
  v_res         jsonb;
BEGIN
  v_sucursal_id := current_sucursal_id();
  IF v_sucursal_id IS NULL THEN
    RAISE EXCEPTION 'Sucursal no seleccionada';
  END IF;
  -- Los roles de obtener_resumen_rendiciones (#724): el transportista ve solo
  -- lo suyo (null = yo); es_transportista() incluye al admin, que ya entro
  -- por la rama de arriba (trampa 4).
  IF NOT es_encargado_o_admin() THEN
    IF NOT es_transportista() THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
    IF p_transportista_id IS NOT NULL AND p_transportista_id <> auth.uid() THEN
      RAISE EXCEPTION 'Acceso denegado' USING ERRCODE = '42501';
    END IF;
    p_transportista_id := auth.uid();
  END IF;

  -- Las columnas de GASTO_COLUMNAS (src/hooks/queries/gastoColumnas.ts), mas
  -- la rendicion, los km de la carga y updated_at, que el cierre devuelve en
  -- vistos. Un compartido tambien: es plata de esta rendicion.
  SELECT COALESCE(jsonb_agg(jsonb_build_object(
           'id', g.id, 'sucursal_id', g.sucursal_id, 'compartido', g.compartido, 'fecha', g.fecha,
           'rubro_id', g.rubro_id, 'monto_total', g.monto_total, 'comprobante', g.comprobante,
           'comprobante_numero', g.comprobante_numero, 'alicuota_iva', g.alicuota_iva, 'iva', g.iva,
           'percepcion_iva', g.percepcion_iva, 'percepcion_iibb', g.percepcion_iibb,
           'otros_impuestos', g.otros_impuestos, 'neto', g.neto, 'costo', g.costo,
           'vehiculo_id', g.vehiculo_id, 'litros', g.litros, 'mes_imputado', g.mes_imputado,
           'repartir_meses', g.repartir_meses, 'mes_fin', g.mes_fin, 'origen_pago', g.origen_pago,
           'observacion', g.observacion, 'creado_por', g.creado_por, 'anulado_at', g.anulado_at,
           'created_at', g.created_at, 'updated_at', g.updated_at,
           'rendicion_transportista_id', g.rendicion_transportista_id, 'rendicion_fecha', g.rendicion_fecha,
           'rubro', jsonb_build_object('id', r.id, 'nombre', r.nombre, 'grupo', r.grupo,
                                       'pide_litros_km', r.pide_litros_km),
           'vehiculo', CASE WHEN v.id IS NULL THEN NULL
                            ELSE jsonb_build_object('id', v.id, 'patente', v.patente, 'descripcion', v.descripcion) END,
           'km_tablero', k.km)
         ORDER BY g.rendicion_fecha DESC, g.rendicion_transportista_id, g.id), '[]'::jsonb)
    INTO v_res
    FROM gastos g
    JOIN gasto_rubros r ON r.id = g.rubro_id
    LEFT JOIN vehiculos v ON v.id = g.vehiculo_id
    LEFT JOIN vehiculo_km k ON k.gasto_id = g.id
   WHERE g.origen_pago = 'rendicion'
     AND g.anulado_at IS NULL
     AND g.sucursal_id = v_sucursal_id
     AND g.rendicion_fecha BETWEEN p_fecha_desde AND p_fecha_hasta
     AND (p_transportista_id IS NULL OR g.rendicion_transportista_id = p_transportista_id);

  RETURN v_res;
END
$function$;

-- -------------------------------------------------------------------------
-- 6 · Las RPCs de Personal
-- -------------------------------------------------------------------------
CREATE FUNCTION public.listar_personal()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE((SELECT jsonb_agg(public._empleado_json(e) ORDER BY e.nombre, e.id)
                     FROM empleados e
                    WHERE public._empleado_visible(e.sucursal_id, e.de_las_dos)), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.obtener_cuenta_empleado(p_empleado_id bigint)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e empleados%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  RETURN jsonb_build_object(
    'empleado', public._empleado_json(v_e),
    'arreglos', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'id', a.id, 'vigente_desde', a.vigente_desde,
               'vigente_hasta', (SELECT min(b.vigente_desde) - 1 FROM empleado_arreglos b
                                  WHERE b.empleado_id = a.empleado_id AND b.vigente_desde > a.vigente_desde),
               'sueldo', a.sueldo, 'frecuencia', a.frecuencia, 'comisiona', a.comisiona)
             ORDER BY a.vigente_desde DESC)
        FROM empleado_arreglos a WHERE a.empleado_id = v_e.id), '[]'::jsonb),
    'movimientos', COALESCE((
      SELECT jsonb_agg(x.j ORDER BY x.fecha DESC, x.id DESC)
        FROM (SELECT m.id, m.fecha,
                     jsonb_build_object(
                       'id', m.id, 'fecha', m.fecha, 'tipo', m.tipo, 'monto', m.monto,
                       'saldo', sum(m.monto) OVER (ORDER BY m.fecha, m.id),
                       'observacion', m.observacion, 'pago_id', m.pago_id, 'pedido_id', m.pedido_id,
                       'gasto', CASE WHEN g.id IS NULL THEN NULL
                                     ELSE jsonb_build_object('id', g.id, 'rubro', r.nombre,
                                                             'vehiculo', CASE WHEN v.id IS NULL THEN NULL
                                                                              ELSE v.descripcion || ' ' || v.patente END) END,
                       'revierte_id', m.revierte_id,
                       'revertido', EXISTS (SELECT 1 FROM empleado_movimientos rv WHERE rv.revierte_id = m.id),
                       'creado_por_nombre', pf.nombre, 'created_at', m.created_at) AS j
                FROM empleado_movimientos m
                LEFT JOIN gastos g ON g.id = m.gasto_id
                LEFT JOIN gasto_rubros r ON r.id = g.rubro_id
                LEFT JOIN vehiculos v ON v.id = g.vehiculo_id
                LEFT JOIN perfiles pf ON pf.id = m.creado_por
               WHERE m.empleado_id = v_e.id) x), '[]'::jsonb));
END
$fn$;

-- Los nombres, sin sueldos ni saldos: para elegir "Un empleado" en un gasto,
-- el vehiculo habitual del cierre y saber si un cliente es un empleado. El
-- mismo filtro para el admin y el encargado: los de la sucursal en la que
-- esta y los "de las dos", que pueden pagar un gasto de cualquiera.
CREATE FUNCTION public.empleados_para_elegir()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_actual bigint := public.current_sucursal_id();
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado eligen un empleado' USING ERRCODE = '42501';
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object('id', e.id, 'nombre', e.nombre, 'usuario_id', e.usuario_id,
                                        'vehiculo_id', e.vehiculo_id, 'activo', e.activo)
                     ORDER BY e.nombre, e.id)
      FROM empleados e
     WHERE v_actual IS NOT NULL AND (e.sucursal_id = v_actual OR e.de_las_dos)), '[]'::jsonb);
END
$fn$;

CREATE FUNCTION public.cliente_admite_adelanto_sueldo(p_cliente_id bigint)
RETURNS boolean
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
BEGIN
  IF NOT public.es_encargado_o_admin() THEN
    RAISE EXCEPTION 'Sólo un admin o el encargado eligen un empleado' USING ERRCODE = '42501';
  END IF;
  RETURN EXISTS (SELECT 1 FROM empleados WHERE cliente_id = p_cliente_id AND activo);
END
$fn$;

-- Alta sin id (con el primer arreglo y el saldo al empezar) y edicion con id
-- (ignora arreglo y saldo_inicial: el arreglo cambia por su RPC, con fecha).
CREATE FUNCTION public.guardar_empleado(p_empleado jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid     uuid := auth.uid();
  v_viejo   empleados%ROWTYPE;
  v_id      bigint;
  v_nombre  text;
  v_puesto  text;
  v_suc     bigint;
  v_dos     boolean;
  v_cuil    text;
  v_ingreso date;
  v_tel     text;
  v_usr     uuid;
  v_cli     bigint;
  v_veh     bigint;
  v_arr     jsonb;
  v_desde   date;
  v_sueldo  numeric;
  v_frec    text;
  v_comis   boolean;
  v_saldo   numeric;
  v_mueve   boolean;
BEGIN
  -- 1 · rol y formato
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_empleado) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;
  BEGIN
    v_id      := NULLIF(p_empleado->>'id', '')::bigint;
    v_nombre  := NULLIF(btrim(p_empleado->>'nombre'), '');
    v_puesto  := NULLIF(btrim(p_empleado->>'puesto'), '');
    v_suc     := NULLIF(p_empleado->>'sucursal_id', '')::bigint;
    v_dos     := (p_empleado->>'de_las_dos')::boolean;
    v_cuil    := NULLIF(regexp_replace(COALESCE(p_empleado->>'cuil', ''), '[^0-9]', '', 'g'), '');
    v_ingreso := NULLIF(p_empleado->>'fecha_ingreso', '')::date;
    v_tel     := NULLIF(btrim(p_empleado->>'telefono'), '');
    v_usr     := NULLIF(btrim(p_empleado->>'usuario_id'), '')::uuid;
    v_cli     := NULLIF(p_empleado->>'cliente_id', '')::bigint;
    v_veh     := NULLIF(p_empleado->>'vehiculo_id', '')::bigint;
    IF v_id IS NULL THEN
      v_arr := p_empleado->'arreglo';
      IF jsonb_typeof(v_arr) = 'object' THEN
        v_desde  := NULLIF(v_arr->>'vigente_desde', '')::date;
        v_sueldo := round(NULLIF(v_arr->>'sueldo', '')::numeric, 2);
        v_frec   := NULLIF(btrim(v_arr->>'frecuencia'), '');
        v_comis  := COALESCE((v_arr->>'comisiona')::boolean, false);
      END IF;
      v_saldo := round(NULLIF(p_empleado->>'saldo_inicial', '')::numeric, 2);
    END IF;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END;
  IF 'NaN'::numeric IN (v_sueldo, v_saldo) OR abs(v_sueldo) > 9999999999.99 OR abs(v_saldo) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;

  -- 2 · en una edicion, la fila bloqueada y visible
  IF v_id IS NOT NULL THEN
    SELECT * INTO v_viejo FROM empleados WHERE id = v_id FOR UPDATE;
    IF NOT FOUND OR NOT public._empleado_visible(v_viejo.sucursal_id, v_viejo.de_las_dos) THEN
      RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
    END IF;
  END IF;
  v_suc := COALESCE(v_suc, v_viejo.sucursal_id, public.current_sucursal_id());
  v_dos := COALESCE(v_dos, v_viejo.de_las_dos, false);

  -- 3 · sucursal
  IF v_suc IS NULL OR NOT EXISTS (SELECT 1 FROM usuario_sucursales us JOIN sucursales s ON s.id = us.sucursal_id
                                   WHERE us.usuario_id = v_uid AND us.sucursal_id = v_suc AND s.activa) THEN
    RAISE EXCEPTION 'No tenés asignada esa sucursal: el empleado va en una de tus sucursales';
  END IF;
  IF v_id IS NULL AND v_dos AND NOT public._tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'Sólo un admin de todas las sucursales carga un empleado de las dos';
  END IF;
  v_mueve := v_id IS NOT NULL AND (v_suc <> v_viejo.sucursal_id OR v_dos <> v_viejo.de_las_dos);
  IF v_mueve AND NOT public._tiene_todas_las_sucursales() THEN
    RAISE EXCEPTION 'La sucursal y «las dos» sólo las cambia un admin de todas las sucursales';
  END IF;

  -- 4 · nombre, puesto y CUIL
  IF v_nombre IS NULL THEN
    RAISE EXCEPTION 'Falta el nombre y apellido';
  END IF;
  IF v_puesto IS NULL OR v_puesto NOT IN ('preventista', 'transportista', 'ayudante', 'deposito',
                                          'administracion', 'encargado', 'otro') THEN
    RAISE EXCEPTION 'Elegí el puesto';
  END IF;
  IF v_cuil IS NOT NULL AND v_cuil !~ '^[0-9]{11}$' THEN
    RAISE EXCEPTION 'El CUIL tiene que tener 11 números';
  END IF;

  -- 5 · uno mismo: nadie pone ni saca el vinculo de su propio usuario
  IF (v_id IS NULL AND v_usr = v_uid)
     OR (v_id IS NOT NULL AND v_usr IS DISTINCT FROM v_viejo.usuario_id
         AND (v_viejo.usuario_id = v_uid OR v_usr = v_uid)) THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;

  -- 6 · vinculos. La unicidad se lee antes, para no dar un 23505. Un vinculo
  --     que no cambia (ni la sucursal) no se vuelve a validar.
  IF v_usr IS NOT NULL AND (v_id IS NULL OR v_mueve OR v_usr IS DISTINCT FROM v_viejo.usuario_id) THEN
    IF EXISTS (SELECT 1 FROM empleados WHERE usuario_id = v_usr AND id IS DISTINCT FROM v_id) THEN
      RAISE EXCEPTION 'Ese usuario ya está vinculado a otro empleado';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM usuario_sucursales WHERE usuario_id = v_usr AND (v_dos OR sucursal_id = v_suc)) THEN
      RAISE EXCEPTION 'Ese usuario no tiene asignada la sucursal del empleado';
    END IF;
  END IF;
  IF v_cli IS NOT NULL AND (v_id IS NULL OR v_mueve OR v_cli IS DISTINCT FROM v_viejo.cliente_id) THEN
    IF EXISTS (SELECT 1 FROM empleados WHERE cliente_id = v_cli AND id IS DISTINCT FROM v_id) THEN
      RAISE EXCEPTION 'Esa ficha de cliente ya está vinculada a otro empleado';
    END IF;
    -- Los inactivos tambien: el empleado puede tener una ficha vieja.
    IF NOT EXISTS (SELECT 1 FROM clientes WHERE id = v_cli AND (v_dos OR sucursal_id = v_suc)) THEN
      RAISE EXCEPTION 'El cliente tiene que ser de la sucursal del empleado';
    END IF;
  END IF;
  IF v_veh IS NOT NULL AND (v_id IS NULL OR v_mueve OR v_veh IS DISTINCT FROM v_viejo.vehiculo_id)
     AND NOT EXISTS (SELECT 1 FROM vehiculos WHERE id = v_veh AND (v_dos OR sucursal_id = v_suc) AND activo) THEN
    RAISE EXCEPTION 'El vehículo no es de la sucursal del empleado o está dado de baja';
  END IF;

  -- 7 · edicion
  IF v_id IS NOT NULL THEN
    UPDATE empleados
       SET nombre = v_nombre, puesto = v_puesto, sucursal_id = v_suc, de_las_dos = v_dos, cuil = v_cuil,
           fecha_ingreso = v_ingreso, telefono = v_tel, usuario_id = v_usr, cliente_id = v_cli,
           vehiculo_id = v_veh, updated_at = now()
     WHERE id = v_id;
    RETURN v_id;
  END IF;

  -- 8 · alta: el primer arreglo (las reglas de guardar_arreglo_empleado)
  IF v_desde IS NULL OR v_sueldo IS NULL OR v_frec IS NULL THEN
    RAISE EXCEPTION 'Falta el primer arreglo: el sueldo, cada cuánto y desde cuándo se liquida';
  END IF;
  IF v_sueldo < 0 THEN
    RAISE EXCEPTION 'El sueldo no puede ser negativo';
  END IF;
  IF v_frec NOT IN ('semanal', 'mensual') THEN
    RAISE EXCEPTION 'El sueldo es semanal o mensual';
  END IF;
  IF v_sueldo = 0 AND NOT v_comis THEN
    RAISE EXCEPTION 'Un arreglo sin sueldo fijo tiene que comisionar';
  END IF;

  INSERT INTO empleados (sucursal_id, de_las_dos, nombre, puesto, cuil, fecha_ingreso, telefono,
                         usuario_id, cliente_id, vehiculo_id, creado_por)
  VALUES (v_suc, v_dos, v_nombre, v_puesto, v_cuil, v_ingreso, v_tel, v_usr, v_cli, v_veh, v_uid)
  RETURNING id INTO v_id;
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
  VALUES (v_id, v_desde, v_sueldo, v_frec, v_comis, v_uid);
  IF COALESCE(v_saldo, 0) <> 0 THEN
    INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por)
    -- Nunca futura: un arreglo puede empezar la semana que viene.
    VALUES (v_id, LEAST(v_desde, public._tablero_hoy()), 'ajuste', v_saldo, 'Saldo al empezar', v_uid);
  END IF;
  RETURN v_id;
END
$fn$;

-- Uno nuevo vale desde despues del ultimo; con la misma fecha, lo corrige.
CREATE FUNCTION public.guardar_arreglo_empleado(p_empleado_id bigint, p_arreglo jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_uid    uuid := auth.uid();
  v_e      empleados%ROWTYPE;
  v_desde  date;
  v_sueldo numeric;
  v_frec   text;
  v_comis  boolean;
  v_ultimo empleado_arreglos%ROWTYPE;
  v_id     bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = v_uid THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  IF NOT v_e.activo THEN
    RAISE EXCEPTION 'Ese empleado está dado de baja: reactivalo para cambiarle el arreglo';
  END IF;
  BEGIN
    IF jsonb_typeof(p_arreglo) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_desde  := NULLIF(p_arreglo->>'vigente_desde', '')::date;
    v_sueldo := round(NULLIF(p_arreglo->>'sueldo', '')::numeric, 2);
    v_frec   := NULLIF(btrim(p_arreglo->>'frecuencia'), '');
    v_comis  := COALESCE((p_arreglo->>'comisiona')::boolean, false);
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END;
  IF 'NaN'::numeric = v_sueldo OR abs(v_sueldo) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;
  IF v_desde IS NULL OR v_sueldo IS NULL OR v_frec IS NULL THEN
    RAISE EXCEPTION 'Falta el primer arreglo: el sueldo, cada cuánto y desde cuándo se liquida';
  END IF;
  IF v_sueldo < 0 THEN
    RAISE EXCEPTION 'El sueldo no puede ser negativo';
  END IF;
  IF v_frec NOT IN ('semanal', 'mensual') THEN
    RAISE EXCEPTION 'El sueldo es semanal o mensual';
  END IF;
  IF v_sueldo = 0 AND NOT v_comis THEN
    RAISE EXCEPTION 'Un arreglo sin sueldo fijo tiene que comisionar';
  END IF;

  SELECT * INTO v_ultimo FROM empleado_arreglos WHERE empleado_id = v_e.id ORDER BY vigente_desde DESC LIMIT 1;
  IF FOUND AND v_desde < v_ultimo.vigente_desde THEN
    RAISE EXCEPTION 'Un arreglo nuevo vale desde después del vigente (%): para corregir el vigente usá su misma fecha',
      to_char(v_ultimo.vigente_desde, 'DD/MM/YYYY');
  END IF;
  IF FOUND AND v_desde = v_ultimo.vigente_desde THEN
    UPDATE empleado_arreglos
       SET sueldo = v_sueldo, frecuencia = v_frec, comisiona = v_comis, updated_at = now()
     WHERE id = v_ultimo.id;
    RETURN v_ultimo.id;
  END IF;
  INSERT INTO empleado_arreglos (empleado_id, vigente_desde, sueldo, frecuencia, comisiona, creado_por)
  VALUES (v_e.id, v_desde, v_sueldo, v_frec, v_comis, v_uid)
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

CREATE FUNCTION public.dar_de_baja_empleado(p_empleado_id bigint, p_fecha date)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e     empleados%ROWTYPE;
  v_fecha date := COALESCE(p_fecha, public._tablero_hoy());
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  IF NOT v_e.activo THEN
    RAISE EXCEPTION 'Ese empleado ya está dado de baja';
  END IF;
  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La baja no puede ser de un día que todavía no llegó';
  END IF;
  -- Con el arranque en el futuro vale hoy: el que nunca se presento tiene salida.
  IF v_fecha < LEAST((SELECT min(vigente_desde) FROM empleado_arreglos WHERE empleado_id = v_e.id),
                     public._tablero_hoy()) THEN
    RAISE EXCEPTION 'La baja no puede ser antes de que empiece su primer arreglo';
  END IF;
  UPDATE empleados SET activo = false, fecha_baja = v_fecha, updated_at = now() WHERE id = v_e.id;
END
$fn$;

CREATE FUNCTION public.reactivar_empleado(p_empleado_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e empleados%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  IF v_e.activo THEN
    RAISE EXCEPTION 'Ese empleado ya está activo';
  END IF;
  UPDATE empleados SET activo = true, fecha_baja = NULL, updated_at = now() WHERE id = v_e.id;
END
$fn$;

-- El adelanto va positivo y se guarda negativo; el ajuste, con su signo. Un
-- empleado dado de baja tambien recibe movimientos: el que se fue debiendo.
CREATE FUNCTION public.registrar_movimiento_empleado(p_empleado_id bigint, p_movimiento jsonb)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_e     empleados%ROWTYPE;
  v_tipo  text;
  v_monto numeric;
  v_fecha date;
  v_obs   text;
  v_id    bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO v_e FROM empleados WHERE id = p_empleado_id FOR UPDATE;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  BEGIN
    IF jsonb_typeof(p_movimiento) IS DISTINCT FROM 'object' THEN
      RAISE EXCEPTION 'formato';
    END IF;
    v_tipo  := NULLIF(btrim(p_movimiento->>'tipo'), '');
    v_monto := round(NULLIF(p_movimiento->>'monto', '')::numeric, 2);
    v_fecha := COALESCE(NULLIF(p_movimiento->>'fecha', '')::date, public._tablero_hoy());
    v_obs   := NULLIF(btrim(p_movimiento->>'observacion'), '');
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END;
  IF 'NaN'::numeric = v_monto OR abs(v_monto) > 9999999999.99 THEN
    RAISE EXCEPTION 'Hay un dato del empleado con un formato inválido';
  END IF;
  IF v_tipo IS NULL OR v_tipo NOT IN ('adelanto', 'ajuste') THEN
    RAISE EXCEPTION 'Un movimiento a mano es un adelanto en efectivo o un ajuste';
  END IF;
  IF v_tipo = 'adelanto' THEN
    IF v_monto IS NULL OR v_monto <= 0 THEN
      RAISE EXCEPTION 'El monto tiene que ser mayor a cero';
    END IF;
    v_monto := -v_monto;
  ELSE
    IF v_monto IS NULL OR v_monto = 0 THEN
      RAISE EXCEPTION 'El ajuste no puede ser cero';
    END IF;
    IF v_obs IS NULL THEN
      RAISE EXCEPTION 'El ajuste necesita una observación que diga por qué';
    END IF;
  END IF;
  IF v_fecha > public._tablero_hoy() THEN
    RAISE EXCEPTION 'La fecha del movimiento no puede ser futura';
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, creado_por)
  VALUES (v_e.id, v_fecha, v_tipo, v_monto, v_obs, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

-- Solo lo cargado a mano, una vez y con motivo. Los automaticos siguen a su
-- pago o a su gasto.
CREATE FUNCTION public.revertir_movimiento_empleado(p_movimiento_id bigint, p_motivo text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_m  empleado_movimientos%ROWTYPE;
  v_e  empleados%ROWTYPE;
  v_id bigint;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin ve y carga el personal' USING ERRCODE = '42501';
  END IF;
  -- El empleado antes que el movimiento: el mismo orden de locks que
  -- registrar_movimiento_empleado.
  SELECT e.* INTO v_e FROM empleados e JOIN empleado_movimientos m ON m.empleado_id = e.id
   WHERE m.id = p_movimiento_id FOR UPDATE OF e;
  IF NOT FOUND OR NOT public._empleado_visible(v_e.sucursal_id, v_e.de_las_dos) THEN
    RAISE EXCEPTION 'Ese empleado no existe o no lo podés ver';
  END IF;
  IF v_e.usuario_id = auth.uid() THEN
    RAISE EXCEPTION 'Tu propia cuenta la maneja otro admin: no podés cambiar tu arreglo, tu usuario ni tus movimientos';
  END IF;
  SELECT * INTO v_m FROM empleado_movimientos WHERE id = p_movimiento_id;
  IF v_m.tipo NOT IN ('adelanto', 'ajuste') THEN
    RAISE EXCEPTION 'Sólo se revierte un movimiento cargado a mano';
  END IF;
  IF v_m.revierte_id IS NOT NULL THEN
    RAISE EXCEPTION 'Un movimiento que revierte a otro no se revierte: cargá uno nuevo';
  END IF;
  IF EXISTS (SELECT 1 FROM empleado_movimientos WHERE revierte_id = v_m.id) THEN
    RAISE EXCEPTION 'Ese movimiento ya está revertido';
  END IF;
  IF p_motivo IS NULL OR btrim(p_motivo) = '' THEN
    RAISE EXCEPTION 'Escribí por qué se revierte';
  END IF;
  INSERT INTO empleado_movimientos (empleado_id, fecha, tipo, monto, observacion, revierte_id, creado_por)
  VALUES (v_m.empleado_id, public._tablero_hoy(), v_m.tipo, -v_m.monto, btrim(p_motivo), v_m.id, auth.uid())
  RETURNING id INTO v_id;
  RETURN v_id;
END
$fn$;

-- -------------------------------------------------------------------------
-- 7 · Permisos de las funciones nuevas
-- -------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public._empleado_visible(bigint, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._empleado_json(public.empleados) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._cuenta_empleado_conciliar(text, bigint, bigint, bigint, bigint, bigint, numeric, date, bigint, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._empleado_visible(bigint, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._empleado_json(public.empleados) TO service_role;
GRANT EXECUTE ON FUNCTION public._cuenta_empleado_conciliar(text, bigint, bigint, bigint, bigint, bigint, numeric, date, bigint, text)
  TO service_role;

-- Las de trigger: sin EXECUTE para nadie.
REVOKE ALL ON FUNCTION public.pagos_cuenta_empleado() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.gastos_cuenta_empleado() FROM PUBLIC, anon, authenticated;

REVOKE ALL ON FUNCTION public.listar_personal() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.obtener_cuenta_empleado(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.empleados_para_elegir() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.cliente_admite_adelanto_sueldo(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.guardar_empleado(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.guardar_arreglo_empleado(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.dar_de_baja_empleado(bigint, date) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.reactivar_empleado(bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.registrar_movimiento_empleado(bigint, jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.revertir_movimiento_empleado(bigint, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.listar_personal() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.obtener_cuenta_empleado(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.empleados_para_elegir() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cliente_admite_adelanto_sueldo(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_empleado(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_arreglo_empleado(bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.dar_de_baja_empleado(bigint, date) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.reactivar_empleado(bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.registrar_movimiento_empleado(bigint, jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.revertir_movimiento_empleado(bigint, text) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 8 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  f text;
BEGIN
  FOREACH f IN ARRAY ARRAY['public.empleados', 'public.empleado_arreglos', 'public.empleado_movimientos'] LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = f::regclass)
       OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = f::regclass) THEN
      RAISE EXCEPTION '% quedo sin RLS o con policies', f;
    END IF;
    IF has_table_privilege('anon', f, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_table_privilege('authenticated', f, 'SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
       OR has_any_column_privilege('anon', f, 'SELECT,INSERT,UPDATE,REFERENCES')
       OR has_any_column_privilege('authenticated', f, 'SELECT,INSERT,UPDATE,REFERENCES') THEN
      RAISE EXCEPTION '% quedo con privilegios para anon o authenticated', f;
    END IF;
  END LOOP;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.pagos'::regclass AND tgname = 'trg_pagos_cuenta_empleado')
     OR NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.gastos'::regclass AND tgname = 'trg_gastos_cuenta_empleado') THEN
    RAISE EXCEPTION 'faltan los triggers de la cuenta del empleado';
  END IF;
  FOREACH f IN ARRAY ARRAY['public._empleado_visible(bigint,boolean)', 'public._empleado_json(empleados)',
                           'public._cuenta_empleado_conciliar(text,bigint,bigint,bigint,bigint,bigint,numeric,date,bigint,text)',
                           'public.pagos_cuenta_empleado()', 'public.gastos_cuenta_empleado()',
                           'public._guardar_gasto(jsonb,boolean)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  FOREACH f IN ARRAY ARRAY['public.listar_personal()', 'public.obtener_cuenta_empleado(bigint)',
                           'public.empleados_para_elegir()', 'public.cliente_admite_adelanto_sueldo(bigint)',
                           'public.guardar_empleado(jsonb)', 'public.guardar_arreglo_empleado(bigint,jsonb)',
                           'public.dar_de_baja_empleado(bigint,date)', 'public.reactivar_empleado(bigint)',
                           'public.registrar_movimiento_empleado(bigint,jsonb)',
                           'public.revertir_movimiento_empleado(bigint,text)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % no quedaron como se esperaba', f;
    END IF;
  END LOOP;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public._guardar_gasto(jsonb,boolean)'::regprocedure)
     = '6056ce94ba972040a968111cb02af2f8' THEN
    RAISE EXCEPTION '_guardar_gasto no quedo reescrita';
  END IF;
  IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = 'public.obtener_gastos_rendiciones(date,date,uuid)'::regprocedure)
     = 'ea970259104287b5a93b540b6b277ef2' THEN
    RAISE EXCEPTION 'obtener_gastos_rendiciones no quedo reescrita';
  END IF;
  IF has_function_privilege('anon', 'public.obtener_gastos_rendiciones(date,date,uuid)', 'EXECUTE')
     OR NOT has_function_privilege('authenticated', 'public.obtener_gastos_rendiciones(date,date,uuid)', 'EXECUTE') THEN
    RAISE EXCEPTION 'los EXECUTE de obtener_gastos_rendiciones no quedaron como se esperaba';
  END IF;
END
$verif$;
