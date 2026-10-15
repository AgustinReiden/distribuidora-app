-- =========================================================================
-- LOS COMBOS (#1191, entrega 1 de 4 del diseño #1190)
--
-- Un combo es varios productos que ya existen, comprados juntos, a un precio
-- fijo ("Fernet + Coca a $11.000"). No se crea un producto: un combo en un
-- pedido son LINEAS COMUNES de cada producto, con el total del combo repartido
-- en proporcion al precio que cada unidad tendria sin el combo. Asi el stock lo
-- mueve cada linea por el camino de siempre (lotes, huella), el costo es el de
-- cada producto (costo_valuacion, COSTO-D) y la venta por producto queda
-- prorrateada. "Venta por vendedor" no cambia: mira el total del pedido.
--
-- QUE AGREGA
--   * combos / combo_componentes: la definicion. Un componente es un LUGAR del
--     combo con una cantidad; varias filas con el mismo lugar son alternativas
--     (como un fardo surtido). Se escriben solo por guardar_combo (admin).
--   * pedido_items.combo_id y precio_sin_combo_unitario: la linea de combo y lo
--     que valdria suelta. origen_precio = 'combo' lo pone el trigger.
--   * pedido_combos: la FOTO del combo con el que se armo cada pedido (misma
--     leccion que pedido_promo_reglas, 370): editar el combo no cambia pedidos
--     viejos, y al editar el pedido un combo que ya tenia se mide contra su foto
--     aunque ya no este vigente (la politica rige el alta, trampa 8).
--   * Puras con espejo en src/utils/combos.ts (gate scripts/espejo-combos.mjs):
--     _combo_prorrateo, _combo_total, _combo_cantidad.
--   * combo_fuera_de_regla: lo que valida el server. crear_pedido_completo y
--     actualizar_pedido_items la llaman para todo rol.
--   * combos_vigentes (lo que lee el front) y guardar_combo (alta y edicion).
--   * COMBO-A en auditoria_integridad.
--
-- EL FRONT ARMA, EL SERVER VALIDA
--   El server no calcula precios: valida los del front dentro de la politica
--   (precio_fuera_de_politica, 363/369). Un combo sigue esa regla. El front
--   decide que combos conviene armar (src/utils/combos.ts, armarCombos) y manda
--   las lineas ya partidas; el server comprueba que lo armado sea legitimo:
--     - para todo rol: el combo existe en la sucursal, sus lineas forman un
--       numero entero de combos, un producto por linea, ninguna es regalo;
--     - para quien no es admin, ademas: vigente en LEAST(fecha, hoy) o en hoy
--       (el criterio de regalo_fuera_de_promo, 362/373; en la edicion la fecha
--       del pedido va sin tope), el tope de combos, y el total y el reparto
--       EXACTOS: total = k x precio (excluyente) o k x precio menos lo que la
--       escala ya bajo (acumulable), repartido con _combo_prorrateo. Un combo
--       nunca deja una linea por encima de su precio sin combo.
--   El precio SIN combo de cada linea pasa por precio_fuera_de_politica como
--   cualquier precio: piso y techo. El admin decide el precio, como siempre.
--
-- ESCALAS MAYORISTAS (combos.combina_escalas, default false)
--   - excluyente: la unidad del combo no toma escala ni cuenta para su minimo.
--     Su precio sin combo es la lista con el descuento del cliente.
--   - acumulable: la unidad cuenta para el minimo, su precio sin combo es el de
--     la escala, y la linea manda ademas precio_sin_escala_unitario (no se
--     guarda): de ahi sale lo que el combo descuenta encima de la escala.
--   precio_fuera_de_politica saca del conteo de escalas las unidades de un
--   combo excluyente y les aplica un piso sin escalas.
--
-- UN PRODUCTO EN DOS LINEAS DE VENTA
--   El combo y lo que queda suelto son dos lineas del mismo producto. Por eso:
--     - la clave de linea de la huella (_foto_huella_lineas /
--       _rehacer_huella_lineas, #1097) suma combo_id: una linea que no cambio
--       conserva su huella aunque la otra del mismo producto cambie;
--     - el pre-chequeo de stock de actualizar_pedido_items compara la suma del
--       producto, no una linea contra la primera que encuentre.
--
-- FUERA DE ESTA ENTREGA: la salvedad que rompe el combo segun el motivo (#1192),
-- el analisis (#1193), la sugerencia y las alertas (#1194). El bot no arma
-- combos (crear_pedido_completo_bot arma sus lineas solo, sin combo_id). Un
-- pedido con combos no pasa a vale blanco.
--
-- ORDEN DE DESPLIEGUE: esta migracion ANTES que el front. El front nuevo pide
-- combo_id y precio_sin_combo_unitario en PEDIDO_ITEM_COLUMNAS: sin las
-- columnas, la consulta de pedidos falla entera para todos.
-- =========================================================================

BEGIN;

-- -------------------------------------------------------------------------
-- 0 · Parches de texto (mismo helper que la 363)
-- -------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION pg_temp.rr_parchar(p_def text, p_viejo text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $fn$
BEGIN
  IF (length(p_def) - length(replace(p_def, p_viejo, ''))) / length(p_viejo) <> 1 THEN
    RAISE EXCEPTION '%: el fragmento no aparece exactamente una vez: revisar a mano', p_que;
  END IF;
  RETURN replace(p_def, p_viejo, p_nuevo);
END
$fn$;

-- -------------------------------------------------------------------------
-- 1 · La definicion
-- -------------------------------------------------------------------------
CREATE TABLE public.combos (
  id                  bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  sucursal_id         bigint NOT NULL REFERENCES public.sucursales(id),
  nombre              text NOT NULL CHECK (btrim(nombre) <> ''),
  activo              boolean NOT NULL DEFAULT true,
  fecha_inicio        date NOT NULL,
  fecha_fin           date,
  -- El tope descarta NaN (en numeric, NaN es MAYOR que todo y pasaria un > 0).
  precio              numeric(12,2) NOT NULL CHECK (precio > 0 AND precio <= 9999999999.99),
  combina_escalas     boolean NOT NULL DEFAULT false,
  prioridad           integer NOT NULL DEFAULT 0,
  tope_combos         integer CHECK (tope_combos IS NULL OR tope_combos > 0),
  producto_a_mover_id bigint,
  creado_por          uuid,
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT combos_fechas_check CHECK (fecha_fin IS NULL OR fecha_fin >= fecha_inicio),
  CONSTRAINT combos_id_sucursal_key UNIQUE (id, sucursal_id),
  CONSTRAINT combos_producto_a_mover_fkey
    FOREIGN KEY (producto_a_mover_id, sucursal_id) REFERENCES public.productos (id, sucursal_id)
);

COMMENT ON TABLE public.combos IS
  'Combos: varios productos existentes juntos a un precio fijo, sin producto nuevo (#1190/#1191). Se escribe por guardar_combo.';
COMMENT ON COLUMN public.combos.combina_escalas IS
  'false (excluyente): la unidad del combo no toma escala ni cuenta para su minimo. true (acumulable): cuenta, y el descuento del combo se suma al de la escala.';
COMMENT ON COLUMN public.combos.tope_combos IS
  'Cuantos combos se pueden vender en total (pedidos no cancelados). NULL = sin tope.';
COMMENT ON COLUMN public.combos.producto_a_mover_id IS
  'El producto que el combo quiere mover (analisis de rotacion, #1193). Uno de sus componentes.';

CREATE TABLE public.combo_componentes (
  id          bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  combo_id    bigint NOT NULL,
  sucursal_id bigint NOT NULL,
  componente  integer NOT NULL CHECK (componente BETWEEN 1 AND 20),
  producto_id bigint NOT NULL,
  cantidad    integer NOT NULL CHECK (cantidad BETWEEN 1 AND 1000),
  CONSTRAINT combo_componentes_combo_fkey
    FOREIGN KEY (combo_id, sucursal_id) REFERENCES public.combos (id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT combo_componentes_producto_fkey
    FOREIGN KEY (producto_id, sucursal_id) REFERENCES public.productos (id, sucursal_id),
  CONSTRAINT combo_componentes_producto_key UNIQUE (combo_id, producto_id)
);
CREATE INDEX combo_componentes_producto_idx ON public.combo_componentes (producto_id);

COMMENT ON TABLE public.combo_componentes IS
  'Lugares de un combo. Varias filas con el mismo componente son alternativas (misma cantidad; lo garantiza guardar_combo).';

-- RLS: lee la sucursal activa (el front los necesita para armar pedidos);
-- escribir es de guardar_combo. Sin nada para anon, sin escritura REST (#1135).
ALTER TABLE public.combos ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.combo_componentes ENABLE ROW LEVEL SECURITY;
CREATE POLICY combos_select ON public.combos
  FOR SELECT TO authenticated USING (sucursal_id = public.current_sucursal_id());
CREATE POLICY combo_componentes_select ON public.combo_componentes
  FOR SELECT TO authenticated USING (sucursal_id = public.current_sucursal_id());
REVOKE ALL ON TABLE public.combos, public.combo_componentes FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER
  ON TABLE public.combos, public.combo_componentes FROM authenticated;
GRANT SELECT ON TABLE public.combos, public.combo_componentes TO authenticated;

CREATE TRIGGER audit_combos
  AFTER INSERT OR UPDATE OR DELETE ON public.combos
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();
CREATE TRIGGER audit_combo_componentes
  AFTER INSERT OR UPDATE OR DELETE ON public.combo_componentes
  FOR EACH ROW EXECUTE FUNCTION public.audit_log_changes();

-- -------------------------------------------------------------------------
-- 2 · La linea de combo
-- -------------------------------------------------------------------------
ALTER TABLE public.pedido_items
  ADD COLUMN combo_id bigint,
  ADD COLUMN precio_sin_combo_unitario numeric(12,2);

COMMENT ON COLUMN public.pedido_items.combo_id IS
  'El combo al que pertenece la linea (#1191). Validado por combo_fuera_de_regla; su foto, en pedido_combos.';
COMMENT ON COLUMN public.pedido_items.precio_sin_combo_unitario IS
  'Lo que valdria la unidad sin el combo (con escala si el combo es acumulable). Base del reparto, de la salvedad (#1192) y del descuento otorgado (#1193).';

ALTER TABLE public.pedido_items DROP CONSTRAINT pedido_items_origen_precio_check;
ALTER TABLE public.pedido_items ADD CONSTRAINT pedido_items_origen_precio_check
  CHECK (origen_precio IS NULL OR origen_precio::text = ANY (ARRAY[
    'lista', 'mayorista', 'desc_cliente', 'desc_categoria', 'manual', 'bonificacion',
    'desconocido', 'costo_interno', 'combo']));

ALTER TABLE public.comision_reglas DROP CONSTRAINT comision_reglas_origen_check;
ALTER TABLE public.comision_reglas ADD CONSTRAINT comision_reglas_origen_check
  CHECK (origen_precio IS NULL OR origen_precio::text = ANY (ARRAY[
    'lista', 'mayorista', 'desc_cliente', 'desc_categoria', 'manual', 'bonificacion',
    'desconocido', 'combo']));

ALTER TABLE public.pedido_items
  ADD CONSTRAINT pedido_items_combo_fkey
    FOREIGN KEY (combo_id, sucursal_id) REFERENCES public.combos (id, sucursal_id),
  ADD CONSTRAINT pedido_items_combo_coherente CHECK (
    (combo_id IS NULL AND precio_sin_combo_unitario IS NULL)
    OR (combo_id IS NOT NULL AND precio_sin_combo_unitario > 0
        AND NOT COALESCE(es_bonificacion, false) AND origen_precio = 'combo'));
CREATE INDEX pedido_items_combo_idx ON public.pedido_items (combo_id) WHERE combo_id IS NOT NULL;

-- pedido_items se concede por columna (327, #1003): las nuevas nacen
-- invisibles. Va la lista entera (la de la 338 mas las dos nuevas): el ultimo
-- GRANT de migrations/ es el que compara pedidoItemColumnas.test.ts con
-- PEDIDO_ITEM_COLUMNAS. Volver a conceder las viejas no cambia nada.
GRANT SELECT (id, pedido_id, producto_id, cantidad, precio_unitario, subtotal, es_bonificacion, promocion_id, neto_unitario, iva_unitario, impuestos_internos_unitario, porcentaje_iva, sucursal_id, tp_import_id, descripcion_regalo, stock_al_crear, ingreso_real_unitario, precio_lista_al_crear, origen_precio, descuento_pct, grupo_precio_escala_id, unidades_por_bloque_al_crear, origen_unidades_por_bloque, regalo_cadena_id, combo_id, precio_sin_combo_unitario)
  ON public.pedido_items TO authenticated;

-- El origen de una linea de combo lo pone el server: 'combo', diga lo que diga
-- quien la manda. registrar_origen_precio_items solo pisa NULL/desconocido, asi
-- que tampoco la toca despues.
CREATE OR REPLACE FUNCTION public.completar_origen_precio_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public'
AS $function$
DECLARE
  v_lista numeric;
BEGIN
  IF NEW.precio_lista_al_crear IS NULL THEN
    SELECT precio INTO v_lista FROM productos WHERE id = NEW.producto_id;
    NEW.precio_lista_al_crear := v_lista;
  END IF;
  v_lista := NEW.precio_lista_al_crear;

  IF NEW.descuento_pct IS NULL AND v_lista IS NOT NULL AND v_lista > 0 THEN
    NEW.descuento_pct := greatest(
      -999.99,
      least(999.99, round(((v_lista - NEW.precio_unitario) / v_lista) * 100, 2))
    );
  END IF;

  -- #1191: la linea de un combo (lo valido combo_fuera_de_regla).
  IF NEW.combo_id IS NOT NULL THEN
    NEW.origen_precio := 'combo';
  END IF;

  IF NEW.origen_precio IS NULL THEN
    IF COALESCE(NEW.es_bonificacion, false) THEN
      NEW.origen_precio := 'bonificacion';
    ELSIF v_lista IS NULL OR v_lista <= 0 THEN
      NEW.origen_precio := 'desconocido';
    ELSIF NEW.precio_unitario = v_lista THEN
      NEW.origen_precio := 'lista';
    ELSE
      NEW.origen_precio := 'desconocido';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

-- -------------------------------------------------------------------------
-- 3 · La foto del combo en cada pedido
-- -------------------------------------------------------------------------
CREATE TABLE public.pedido_combos (
  pedido_id       bigint      NOT NULL,
  combo_id        bigint      NOT NULL,
  sucursal_id     bigint      NOT NULL,
  cantidad_combos integer     NOT NULL CHECK (cantidad_combos > 0),
  nombre          text        NOT NULL,
  precio          numeric(12,2) NOT NULL CHECK (precio > 0),
  combina_escalas boolean     NOT NULL,
  -- [{componente, cantidad, productos: [ids]}]
  componentes     jsonb       NOT NULL,
  tomada_at       timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (pedido_id, combo_id),
  FOREIGN KEY (pedido_id, sucursal_id) REFERENCES public.pedidos (id, sucursal_id) ON DELETE CASCADE,
  FOREIGN KEY (combo_id, sucursal_id) REFERENCES public.combos (id, sucursal_id)
);
CREATE INDEX pedido_combos_combo_idx ON public.pedido_combos (combo_id);

COMMENT ON TABLE public.pedido_combos IS
  'Foto del combo con el que se armo cada pedido (#1191). La escribe _guardar_combos_pedido; editar el combo no la cambia.';

-- La lee el front al editar el pedido (para conservar sus combos). Quien ve el
-- pedido ve su foto: la policy de pedidos corre adentro del EXISTS.
ALTER TABLE public.pedido_combos ENABLE ROW LEVEL SECURITY;
CREATE POLICY pedido_combos_select ON public.pedido_combos
  FOR SELECT TO authenticated
  USING (sucursal_id = public.current_sucursal_id()
         AND EXISTS (SELECT 1 FROM public.pedidos p WHERE p.id = pedido_combos.pedido_id));
REVOKE ALL ON TABLE public.pedido_combos FROM PUBLIC, anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER ON TABLE public.pedido_combos FROM authenticated;
GRANT SELECT ON TABLE public.pedido_combos TO authenticated;

-- -------------------------------------------------------------------------
-- 4 · Puras (espejo: src/utils/combos.ts, gate scripts/espejo-combos.mjs)
-- -------------------------------------------------------------------------

-- prorratearTotal: reparte p_total entre las lineas [{producto_id, cantidad,
-- ref}] en proporcion a cantidad x ref, en centavos enteros. Lo que sobra va a
-- la linea mas cara cuya cantidad lo divide; si ninguna, a la de menor
-- cantidad, redondeado. Devuelve {producto_id: precio}. NULL si no hay reparto.
CREATE OR REPLACE FUNCTION public._combo_prorrateo(p_total numeric, p_lineas jsonb)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $fn$
DECLARE
  v_ids   bigint[];
  v_q     numeric[];
  v_c     numeric[];
  v_u     numeric[];
  n       integer;
  i       integer;
  v_j     integer;
  v_t     numeric := round(p_total * 100);
  v_r     numeric := 0;
  v_suma  numeric := 0;
  v_resto numeric;
BEGIN
  IF jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR v_t IS NULL OR v_t <= 0 THEN
    RETURN NULL;
  END IF;
  SELECT array_agg(NULLIF(e->>'producto_id', '')::bigint ORDER BY o),
         array_agg(NULLIF(e->>'cantidad', '')::numeric ORDER BY o),
         array_agg(round(NULLIF(e->>'ref', '')::numeric * 100) ORDER BY o)
    INTO v_ids, v_q, v_c
    FROM jsonb_array_elements(p_lineas) WITH ORDINALITY AS t(e, o);
  n := COALESCE(cardinality(v_ids), 0);
  IF n = 0 THEN RETURN NULL; END IF;
  FOR i IN 1..n LOOP
    IF v_ids[i] IS NULL OR v_q[i] IS NULL OR v_q[i] <= 0 OR v_q[i] <> trunc(v_q[i])
       OR v_c[i] IS NULL OR v_c[i] <= 0 THEN
      RETURN NULL;
    END IF;
    v_r := v_r + v_q[i] * v_c[i];
  END LOOP;

  v_u := array_fill(0::numeric, ARRAY[n]);
  FOR i IN 1..n LOOP
    v_u[i] := div(2 * v_t * v_c[i] + v_r, 2 * v_r);
    v_suma := v_suma + v_q[i] * v_u[i];
  END LOOP;

  v_resto := v_t - v_suma;
  IF v_resto <> 0 THEN
    SELECT s.i INTO v_j
      FROM generate_subscripts(v_ids, 1) AS s(i)
     WHERE mod(v_resto, v_q[s.i]) = 0
     ORDER BY v_c[s.i] DESC, v_ids[s.i]
     LIMIT 1;
    IF v_j IS NOT NULL THEN
      v_u[v_j] := v_u[v_j] + div(v_resto, v_q[v_j]);
    ELSE
      SELECT s.i INTO v_j
        FROM generate_subscripts(v_ids, 1) AS s(i)
       ORDER BY v_q[s.i], v_c[s.i] DESC, v_ids[s.i]
       LIMIT 1;
      v_u[v_j] := v_u[v_j] + sign(v_resto) * div(2 * abs(v_resto) + v_q[v_j], 2 * v_q[v_j]);
    END IF;
  END IF;

  RETURN (SELECT jsonb_object_agg(v_ids[s.i]::text, round(v_u[s.i] / 100, 2))
            FROM generate_subscripts(v_ids, 1) AS s(i));
END
$fn$;

-- totalDelCombo: k x precio, menos (en un acumulable) lo que la escala ya bajo
-- en cada unidad: Σ cantidad x (sin_escala - ref). Las lineas sin sin_escala no
-- restan nada.
CREATE OR REPLACE FUNCTION public._combo_total(p_precio numeric, p_k integer, p_lineas jsonb)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path = public
AS $fn$
  SELECT round((round(p_precio * 100) * p_k
                - COALESCE((SELECT sum(NULLIF(e->>'cantidad', '')::numeric
                                       * (round(NULLIF(e->>'sin_escala', '')::numeric * 100)
                                          - round(NULLIF(e->>'ref', '')::numeric * 100)))
                              FROM jsonb_array_elements(CASE WHEN jsonb_typeof(p_lineas) = 'array'
                                                             THEN p_lineas ELSE '[]'::jsonb END) e
                             WHERE NULLIF(e->>'sin_escala', '') IS NOT NULL), 0)) / 100, 2);
$fn$;

-- cantidadDeCombos: cuantos combos forman las lineas [{producto_id, cantidad}]
-- con los componentes [{componente, cantidad, productos}]. Cada producto en un
-- lugar, cada lugar k x su cantidad, el mismo k >= 1 en todos. NULL si no.
CREATE OR REPLACE FUNCTION public._combo_cantidad(p_componentes jsonb, p_lineas jsonb)
RETURNS integer
LANGUAGE plpgsql
IMMUTABLE
SET search_path = public
AS $fn$
DECLARE
  r     record;
  v_k   numeric;
  v_kc  numeric;
BEGIN
  IF jsonb_typeof(p_componentes) IS DISTINCT FROM 'array' OR jsonb_array_length(p_componentes) = 0
     OR jsonb_typeof(p_lineas) IS DISTINCT FROM 'array' OR jsonb_array_length(p_lineas) = 0 THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_componentes) c
              WHERE COALESCE(c->>'cantidad', '') !~ '^[0-9]{1,9}$' OR (c->>'cantidad')::numeric <= 0) THEN
    RETURN NULL;
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(p_lineas) l
              WHERE COALESCE(l->>'cantidad', '') !~ '^[0-9]{1,9}$' OR (l->>'cantidad')::numeric <= 0
                 OR NOT EXISTS (SELECT 1
                                  FROM jsonb_array_elements(p_componentes) c
                                 CROSS JOIN LATERAL jsonb_array_elements_text(
                                   CASE WHEN jsonb_typeof(c->'productos') = 'array' THEN c->'productos'
                                        ELSE '[]'::jsonb END) p
                                 WHERE p = l->>'producto_id')) THEN
    RETURN NULL;
  END IF;
  FOR r IN
    SELECT (c->>'cantidad')::numeric AS cant,
           COALESCE((SELECT sum((l->>'cantidad')::numeric)
                       FROM jsonb_array_elements(p_lineas) l
                      WHERE l->>'producto_id' IN (
                        SELECT jsonb_array_elements_text(
                                 CASE WHEN jsonb_typeof(c->'productos') = 'array' THEN c->'productos'
                                      ELSE '[]'::jsonb END))), 0) AS suma
      FROM jsonb_array_elements(p_componentes) c
  LOOP
    IF mod(r.suma, r.cant) <> 0 THEN RETURN NULL; END IF;
    v_kc := div(r.suma, r.cant);
    IF v_kc <= 0 THEN RETURN NULL; END IF;
    IF v_k IS NULL THEN
      v_k := v_kc;
    ELSIF v_k <> v_kc THEN
      RETURN NULL;
    END IF;
  END LOOP;
  RETURN v_k::integer;
END
$fn$;

-- La definicion vigente de un combo, con la forma de la foto.
CREATE OR REPLACE FUNCTION public._combo_definicion(p_combo_id bigint, p_sucursal bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SET search_path = public
AS $fn$
  SELECT jsonb_build_object(
           'nombre', c.nombre,
           'precio', c.precio,
           'combina_escalas', c.combina_escalas,
           'componentes', (SELECT jsonb_agg(jsonb_build_object(
                                    'componente', x.componente, 'cantidad', x.cantidad, 'productos', x.productos)
                                  ORDER BY x.componente)
                             FROM (SELECT cc.componente, min(cc.cantidad) AS cantidad,
                                          jsonb_agg(cc.producto_id ORDER BY cc.producto_id) AS productos
                                     FROM combo_componentes cc
                                    WHERE cc.combo_id = c.id AND cc.sucursal_id = c.sucursal_id
                                    GROUP BY cc.componente) x))
    FROM combos c
   WHERE c.id = p_combo_id AND c.sucursal_id = p_sucursal;
$fn$;

-- -------------------------------------------------------------------------
-- 5 · Lo que valida el server
-- -------------------------------------------------------------------------
-- Devuelve NULL si los combos de p_items son legitimos, o el motivo. Lo llaman
-- crear_pedido_completo (p_pedido_id NULL) y actualizar_pedido_items. Con
-- p_validar_politica = false (el admin) solo mira que el combo exista y que sus
-- lineas formen combos enteros: el precio lo decide el admin.
-- VOLATILE porque bloquea la fila del combo con tope (dos altas a la vez no
-- pasan el tope).
CREATE OR REPLACE FUNCTION public.combo_fuera_de_regla(
  p_items jsonb, p_sucursal bigint, p_fecha date, p_pedido_id bigint, p_validar_politica boolean)
RETURNS text
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  v_items    jsonb := CASE WHEN jsonb_typeof(p_items) = 'array' THEN p_items ELSE '[]'::jsonb END;
  v_hoy      date := (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date;
  -- Alta: LEAST(fecha, hoy) (#1152). Edicion: la fecha del pedido sin tope (362).
  v_d        date;
  r          record;
  v_combo    record;
  v_vigente  boolean;
  v_def      jsonb;
  v_nombre   text;
  v_k        integer;
  v_k_foto   integer;
  v_lineas   jsonb;
  v_total    numeric;
  v_ref      numeric;
  v_prorr    jsonb;
  v_vendidos bigint;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
    RETURN NULL;
  END IF;
  v_d := CASE WHEN p_pedido_id IS NULL THEN LEAST(COALESCE(p_fecha, v_hoy), v_hoy)
              ELSE COALESCE(p_fecha, v_hoy) END;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e
              WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
                AND COALESCE((e->>'es_bonificacion')::boolean, false)) THEN
    RETURN 'Un regalo no puede ir dentro de un combo.';
  END IF;
  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_items) e
              WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
              GROUP BY e->>'combo_id', e->>'producto_id'
             HAVING count(*) > 1) THEN
    RETURN 'Un combo trae dos líneas del mismo producto.';
  END IF;

  FOR r IN
    SELECT NULLIF(e->>'combo_id', '')::bigint AS combo_id,
           jsonb_agg(jsonb_build_object(
             'producto_id', NULLIF(e->>'producto_id', '')::bigint,
             'cantidad',    NULLIF(e->>'cantidad', '')::numeric,
             'ref',         NULLIF(e->>'precio_sin_combo_unitario', '')::numeric,
             'sin_escala',  NULLIF(e->>'precio_sin_escala_unitario', '')::numeric,
             'precio',      NULLIF(e->>'precio_unitario', '')::numeric)
             ORDER BY NULLIF(e->>'producto_id', '')::bigint) AS lineas
      FROM jsonb_array_elements(v_items) e
     WHERE NULLIF(e->>'combo_id', '') IS NOT NULL
     GROUP BY 1
     ORDER BY 1
  LOOP
    SELECT * INTO v_combo FROM combos WHERE id = r.combo_id AND sucursal_id = p_sucursal;
    IF NOT FOUND THEN
      RETURN format('El combo #%s no existe en esta sucursal.', r.combo_id);
    END IF;

    v_vigente := v_combo.activo
                 AND ((v_combo.fecha_inicio <= v_d AND (v_combo.fecha_fin IS NULL OR v_combo.fecha_fin >= v_d))
                      OR (v_combo.fecha_inicio <= v_hoy AND (v_combo.fecha_fin IS NULL OR v_combo.fecha_fin >= v_hoy)));

    -- Edicion: el combo que el pedido ya tenia se mide contra su foto.
    v_def := NULL;
    v_k_foto := NULL;
    IF p_pedido_id IS NOT NULL THEN
      SELECT jsonb_build_object('nombre', f.nombre, 'precio', f.precio,
                                'combina_escalas', f.combina_escalas, 'componentes', f.componentes),
             f.cantidad_combos
        INTO v_def, v_k_foto
        FROM pedido_combos f
       WHERE f.pedido_id = p_pedido_id AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;
    END IF;
    IF v_def IS NULL THEN
      IF p_validar_politica AND NOT v_vigente THEN
        RETURN format('El combo "%s" no está vigente.', v_combo.nombre);
      END IF;
      v_def := public._combo_definicion(r.combo_id, p_sucursal);
    END IF;
    v_nombre := v_def->>'nombre';

    v_k := public._combo_cantidad(v_def->'componentes', r.lineas);
    IF v_k IS NULL THEN
      RETURN format('Las líneas del combo "%s" no forman un número entero de combos.', v_nombre);
    END IF;
    -- Un combo que ya no esta vigente se conserva con su foto, pero no crece.
    IF p_validar_politica AND v_k_foto IS NOT NULL AND NOT v_vigente AND v_k > v_k_foto THEN
      RETURN format('El combo "%s" ya no está vigente: el pedido puede conservar sus %s, no sumar más.',
                    v_nombre, v_k_foto);
    END IF;
    IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.lineas) x
                WHERE COALESCE((x->>'ref')::numeric, 0) <= 0 OR COALESCE((x->>'precio')::numeric, 0) <= 0) THEN
      RETURN format('Una línea del combo "%s" viene sin su precio sin combo.', v_nombre);
    END IF;

    CONTINUE WHEN NOT p_validar_politica;

    -- Acumulable: cada linea trae su precio sin escalas, no menor que el de
    -- referencia. Excluyente: no resta nada (se ignora si vino).
    IF (v_def->>'combina_escalas')::boolean THEN
      IF EXISTS (SELECT 1 FROM jsonb_array_elements(r.lineas) x
                  WHERE (x->>'sin_escala') IS NULL OR (x->>'sin_escala')::numeric < (x->>'ref')::numeric) THEN
        RETURN format('Una línea del combo "%s" viene sin su precio sin escala.', v_nombre);
      END IF;
      v_lineas := r.lineas;
    ELSE
      SELECT jsonb_agg(x - 'sin_escala') INTO v_lineas FROM jsonb_array_elements(r.lineas) x;
    END IF;

    v_total := public._combo_total((v_def->>'precio')::numeric, v_k, v_lineas);
    SELECT sum((x->>'cantidad')::numeric * (x->>'ref')::numeric) INTO v_ref
      FROM jsonb_array_elements(v_lineas) x;
    IF v_total IS NULL OR v_total <= 0 THEN
      RETURN format('El combo "%s" no deja nada para cobrar.', v_nombre);
    END IF;
    IF v_total > v_ref + 0.005 THEN
      RETURN format('El combo "%s" sale más caro que comprar sus productos sueltos.', v_nombre);
    END IF;
    v_prorr := public._combo_prorrateo(v_total, v_lineas);
    IF v_prorr IS NULL
       OR EXISTS (SELECT 1 FROM jsonb_array_elements(v_lineas) x
                   WHERE abs((x->>'precio')::numeric - (v_prorr->>(x->>'producto_id'))::numeric) > 0.001) THEN
      RETURN format('El precio de las líneas del combo "%s" no coincide con su reparto. Recargá la app y volvé a armar el pedido.', v_nombre);
    END IF;

    IF v_combo.tope_combos IS NOT NULL THEN
      PERFORM 1 FROM combos WHERE id = r.combo_id AND sucursal_id = p_sucursal FOR UPDATE;
      SELECT COALESCE(sum(f.cantidad_combos), 0) INTO v_vendidos
        FROM pedido_combos f
        JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
       WHERE f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal
         AND p.estado NOT IN ('cancelado', 'anulado')
         AND f.pedido_id IS DISTINCT FROM p_pedido_id;
      IF v_vendidos + v_k > v_combo.tope_combos THEN
        RETURN format('El combo "%s" llegó a su tope: quedan %s.', v_nombre,
                      GREATEST(v_combo.tope_combos - v_vendidos, 0));
      END IF;
    END IF;
  END LOOP;

  RETURN NULL;
END
$fn$;

-- La foto de los combos de un pedido, desde sus lineas guardadas. Un combo que
-- el pedido ya tenia conserva su foto (solo cambia la cantidad); uno nuevo se
-- fotografia de la definicion de hoy; uno que ya no esta se borra.
CREATE OR REPLACE FUNCTION public._guardar_combos_pedido(p_pedido_id bigint, p_sucursal bigint)
RETURNS void
LANGUAGE plpgsql
SET search_path = public
AS $fn$
DECLARE
  r     record;
  v_def jsonb;
  v_k   integer;
BEGIN
  DELETE FROM pedido_combos f
   WHERE f.pedido_id = p_pedido_id AND f.sucursal_id = p_sucursal
     AND NOT EXISTS (SELECT 1 FROM pedido_items pi
                      WHERE pi.pedido_id = f.pedido_id AND pi.sucursal_id = f.sucursal_id
                        AND pi.combo_id = f.combo_id);

  FOR r IN
    SELECT pi.combo_id,
           jsonb_agg(jsonb_build_object('producto_id', pi.producto_id, 'cantidad', pi.cantidad)) AS lineas
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal AND pi.combo_id IS NOT NULL
     GROUP BY pi.combo_id
  LOOP
    SELECT f.componentes INTO v_def
      FROM pedido_combos f
     WHERE f.pedido_id = p_pedido_id AND f.combo_id = r.combo_id AND f.sucursal_id = p_sucursal;
    IF FOUND THEN
      v_k := public._combo_cantidad(v_def, r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      UPDATE pedido_combos SET cantidad_combos = v_k
       WHERE pedido_id = p_pedido_id AND combo_id = r.combo_id AND sucursal_id = p_sucursal;
    ELSE
      v_def := public._combo_definicion(r.combo_id, p_sucursal);
      v_k := public._combo_cantidad(v_def->'componentes', r.lineas);
      IF v_k IS NULL THEN
        RAISE EXCEPTION 'Las líneas del combo #% del pedido #% no forman combos enteros', r.combo_id, p_pedido_id;
      END IF;
      INSERT INTO pedido_combos (pedido_id, combo_id, sucursal_id, cantidad_combos, nombre, precio,
                                 combina_escalas, componentes)
      VALUES (p_pedido_id, r.combo_id, p_sucursal, v_k, v_def->>'nombre', (v_def->>'precio')::numeric,
              (v_def->>'combina_escalas')::boolean, v_def->'componentes');
    END IF;
  END LOOP;
END
$fn$;

-- -------------------------------------------------------------------------
-- 6 · Lo que usa el front
-- -------------------------------------------------------------------------
-- Los combos vigentes en p_fecha (NULL = hoy) de la sucursal activa, con sus
-- componentes y lo que les queda de tope. p_pedido_id: en la edicion, no
-- cuenta los combos de ese pedido contra el tope. DEFINER porque el tope suma
-- pedidos de todos los vendedores.
CREATE OR REPLACE FUNCTION public.combos_vigentes(p_fecha date DEFAULT NULL, p_pedido_id bigint DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_d        date := COALESCE(p_fecha, (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date);
BEGIN
  IF auth.uid() IS NULL OR v_sucursal IS NULL THEN
    RETURN '[]'::jsonb;
  END IF;
  RETURN COALESCE((
    SELECT jsonb_agg(jsonb_build_object(
             'id', c.id,
             'nombre', c.nombre,
             'precio', c.precio,
             'combina_escalas', c.combina_escalas,
             'prioridad', c.prioridad,
             'producto_a_mover_id', c.producto_a_mover_id,
             'componentes', d.def->'componentes',
             'tope_restante', CASE WHEN c.tope_combos IS NULL THEN NULL ELSE GREATEST(c.tope_combos - COALESCE((
                                SELECT sum(f.cantidad_combos)
                                  FROM pedido_combos f
                                  JOIN pedidos p ON p.id = f.pedido_id AND p.sucursal_id = f.sucursal_id
                                 WHERE f.combo_id = c.id AND f.sucursal_id = c.sucursal_id
                                   AND p.estado NOT IN ('cancelado', 'anulado')
                                   AND f.pedido_id IS DISTINCT FROM p_pedido_id), 0), 0) END)
           ORDER BY c.prioridad DESC, c.id)
      FROM combos c
      CROSS JOIN LATERAL (SELECT public._combo_definicion(c.id, c.sucursal_id) AS def) d
     WHERE c.sucursal_id = v_sucursal
       AND c.activo
       AND c.fecha_inicio <= v_d
       AND (c.fecha_fin IS NULL OR c.fecha_fin >= v_d)
       AND d.def->'componentes' IS NOT NULL
       AND jsonb_typeof(d.def->'componentes') = 'array'), '[]'::jsonb);
END
$fn$;

-- Alta y edicion de un combo (admin). p_combo: {id?, nombre, precio,
-- fecha_inicio, fecha_fin?, activo?, combina_escalas?, prioridad?,
-- tope_combos?, producto_a_mover_id?, componentes: [{cantidad, productos: [ids]}]}.
-- Los componentes se reemplazan enteros; el numero de lugar es su posicion.
-- Editar un combo no toca los pedidos que ya lo tienen (pedido_combos).
CREATE OR REPLACE FUNCTION public.guardar_combo(p_combo jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal bigint := public.current_sucursal_id();
  v_id       bigint;
  v_nombre   text;
  v_precio   numeric;
  v_inicio   date;
  v_fin      date;
  v_activo   boolean;
  v_escalas  boolean;
  v_prior    integer;
  v_tope     integer;
  v_mover    bigint;
  v_comp     jsonb;
  v_unidades integer;
  v_prods    bigint[];
  v_err      text;
BEGIN
  IF NOT public.es_admin() THEN
    RETURN jsonb_build_object('success', false, 'error', 'Solo un admin puede crear o editar combos.');
  END IF;
  IF v_sucursal IS NULL THEN
    RETURN jsonb_build_object('success', false, 'error', 'No se pudo determinar la sucursal activa.');
  END IF;
  IF jsonb_typeof(p_combo) IS DISTINCT FROM 'object' THEN
    RETURN jsonb_build_object('success', false, 'error', 'Faltan los datos del combo.');
  END IF;

  BEGIN
    v_id      := NULLIF(p_combo->>'id', '')::bigint;
    v_nombre  := btrim(COALESCE(p_combo->>'nombre', ''));
    v_precio  := NULLIF(p_combo->>'precio', '')::numeric;
    v_inicio  := NULLIF(p_combo->>'fecha_inicio', '')::date;
    v_fin     := NULLIF(p_combo->>'fecha_fin', '')::date;
    v_activo  := COALESCE((p_combo->>'activo')::boolean, true);
    v_escalas := COALESCE((p_combo->>'combina_escalas')::boolean, false);
    v_prior   := COALESCE(NULLIF(p_combo->>'prioridad', '')::integer, 0);
    v_tope    := NULLIF(p_combo->>'tope_combos', '')::integer;
    v_mover   := NULLIF(p_combo->>'producto_a_mover_id', '')::bigint;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un dato del combo con un formato inválido.');
  END;
  v_comp := CASE WHEN jsonb_typeof(p_combo->'componentes') = 'array' THEN p_combo->'componentes' ELSE '[]'::jsonb END;

  v_err := CASE
    WHEN v_nombre = '' THEN 'El combo necesita un nombre.'
    WHEN v_precio IS NULL OR NOT (v_precio > 0 AND v_precio <= 9999999999.99) THEN 'El precio del combo tiene que ser mayor que cero.'
    WHEN v_precio <> round(v_precio, 2) THEN 'El precio del combo va con dos decimales como máximo.'
    WHEN v_inicio IS NULL THEN 'El combo necesita una fecha de inicio.'
    WHEN v_fin IS NOT NULL AND v_fin < v_inicio THEN 'La fecha de fin no puede ser anterior a la de inicio.'
    WHEN v_tope IS NOT NULL AND v_tope <= 0 THEN 'El tope de combos tiene que ser mayor que cero.'
    WHEN jsonb_array_length(v_comp) = 0 THEN 'El combo necesita al menos un producto.'
    WHEN jsonb_array_length(v_comp) > 20 THEN 'Un combo puede tener hasta 20 lugares.'
  END;
  IF v_err IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'error', v_err);
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_comp) c
              WHERE COALESCE(c->>'cantidad', '') !~ '^[0-9]{1,4}$'
                 OR (c->>'cantidad')::integer NOT BETWEEN 1 AND 1000
                 OR jsonb_typeof(c->'productos') IS DISTINCT FROM 'array'
                 OR jsonb_array_length(c->'productos') = 0) THEN
    RETURN jsonb_build_object('success', false, 'error',
      'Cada lugar del combo necesita una cantidad entre 1 y 1000 y al menos un producto.');
  END IF;
  SELECT COALESCE(sum((c->>'cantidad')::integer), 0) INTO v_unidades FROM jsonb_array_elements(v_comp) c;
  IF v_unidades < 2 THEN
    RETURN jsonb_build_object('success', false, 'error', 'Un combo junta al menos dos unidades.');
  END IF;
  BEGIN
    SELECT array_agg(p::bigint) INTO v_prods
      FROM jsonb_array_elements(v_comp) c
     CROSS JOIN LATERAL jsonb_array_elements_text(c->'productos') p;
  EXCEPTION WHEN others THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del combo con un formato inválido.');
  END;
  IF cardinality(v_prods) <> (SELECT count(DISTINCT x) FROM unnest(v_prods) x) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Un producto no puede estar dos veces en el mismo combo.');
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_prods) x
              WHERE NOT EXISTS (SELECT 1 FROM productos pr WHERE pr.id = x AND pr.sucursal_id = v_sucursal)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Hay un producto del combo que no es de esta sucursal.');
  END IF;
  IF v_mover IS NOT NULL AND NOT (v_mover = ANY(v_prods)) THEN
    RETURN jsonb_build_object('success', false, 'error', 'El producto a mover tiene que ser uno de los del combo.');
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO combos (sucursal_id, nombre, activo, fecha_inicio, fecha_fin, precio, combina_escalas,
                        prioridad, tope_combos, producto_a_mover_id, creado_por)
    VALUES (v_sucursal, v_nombre, v_activo, v_inicio, v_fin, v_precio, v_escalas,
            v_prior, v_tope, v_mover, auth.uid())
    RETURNING id INTO v_id;
  ELSE
    UPDATE combos
       SET nombre = v_nombre, activo = v_activo, fecha_inicio = v_inicio, fecha_fin = v_fin,
           precio = v_precio, combina_escalas = v_escalas, prioridad = v_prior,
           tope_combos = v_tope, producto_a_mover_id = v_mover, updated_at = now()
     WHERE id = v_id AND sucursal_id = v_sucursal;
    IF NOT FOUND THEN
      RETURN jsonb_build_object('success', false, 'error', 'El combo no existe en esta sucursal.');
    END IF;
    DELETE FROM combo_componentes WHERE combo_id = v_id AND sucursal_id = v_sucursal;
  END IF;

  INSERT INTO combo_componentes (combo_id, sucursal_id, componente, producto_id, cantidad)
  SELECT v_id, v_sucursal, c.o::integer, p::bigint, (c.x->>'cantidad')::integer
    FROM jsonb_array_elements(v_comp) WITH ORDINALITY AS c(x, o)
   CROSS JOIN LATERAL jsonb_array_elements_text(c.x->'productos') p;

  RETURN jsonb_build_object('success', true, 'id', v_id);
END
$fn$;

-- -------------------------------------------------------------------------
-- 7 · Permisos de las funciones nuevas
-- -------------------------------------------------------------------------
-- Las de server: a nadie del front (las tres mitades) y service_role, que usa
-- el gate de paridad.
REVOKE ALL ON FUNCTION public._combo_prorrateo(numeric, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_total(numeric, integer, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_cantidad(jsonb, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._combo_definicion(bigint, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.combo_fuera_de_regla(jsonb, bigint, date, bigint, boolean) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public._guardar_combos_pedido(bigint, bigint) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._combo_prorrateo(numeric, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_total(numeric, integer, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_cantidad(jsonb, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public._combo_definicion(bigint, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.combo_fuera_de_regla(jsonb, bigint, date, bigint, boolean) TO service_role;
GRANT EXECUTE ON FUNCTION public._guardar_combos_pedido(bigint, bigint) TO service_role;
-- Las del front: authenticated, sin anon.
REVOKE ALL ON FUNCTION public.combos_vigentes(date, bigint) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.guardar_combo(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.combos_vigentes(date, bigint) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_combo(jsonb) TO authenticated, service_role;

-- -------------------------------------------------------------------------
-- 8 · precio_fuera_de_politica: las lineas de combo por su precio SIN combo,
--     y las de un combo excluyente sin escala y fuera del conteo de escalas
-- -------------------------------------------------------------------------
DO $politica$
DECLARE
  v_def text := pg_get_functiondef('public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  v_guardado_max numeric;
BEGIN
$q$,
$q$  v_guardado_max numeric;
  -- #1191: los combos.
  v_items_escala     jsonb;
  v_excl_combo       bigint[];
  v_techo_sin_escala numeric;
BEGIN
  -- #1191: una linea de combo se valida por su precio SIN combo (el del combo
  -- lo valida combo_fuera_de_regla). La de un combo excluyente
  -- (combina_escalas = false; en la edicion, el de la foto) no toma escala
  -- (_sin_escala) ni cuenta para el minimo de ninguna (v_items_escala).
  SELECT COALESCE(array_agg(c.id), '{}') INTO v_excl_combo
    FROM combos c
   WHERE c.sucursal_id = p_sucursal
     AND c.id IN (SELECT NULLIF(e->>'combo_id', '')::bigint FROM jsonb_array_elements(v_items) e)
     AND NOT COALESCE((SELECT f.combina_escalas FROM pedido_combos f
                        WHERE f.pedido_id = p_pedido_id AND f.combo_id = c.id AND f.sucursal_id = p_sucursal),
                      c.combina_escalas);
  SELECT COALESCE(jsonb_agg(CASE WHEN NULLIF(x.e->>'combo_id', '') IS NULL THEN x.e
                                 ELSE x.e || jsonb_build_object(
                                        'precio_unitario', x.e->'precio_sin_combo_unitario',
                                        '_sin_escala', NULLIF(x.e->>'combo_id', '')::bigint = ANY(v_excl_combo)) END
                            ORDER BY x.o), '[]'::jsonb)
    INTO v_items
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o);
  SELECT COALESCE(jsonb_agg(x.e ORDER BY x.o), '[]'::jsonb) INTO v_items_escala
    FROM jsonb_array_elements(v_items) WITH ORDINALITY AS x(e, o)
   WHERE NOT COALESCE((x.e->>'_sin_escala')::boolean, false);

$q$, 'politica: declaraciones');

  v_def := pg_temp.rr_parchar(v_def,
$q$    SELECT NULLIF(e->>'producto_id', '')::bigint AS producto,
           min(NULLIF(e->>'precio_unitario', '')::numeric) AS precio,
           max(NULLIF(e->>'precio_unitario', '')::numeric) AS precio_max,
           bool_or(NULLIF(e->>'precio_unitario', '') IS NULL) AS sin_precio
      FROM jsonb_array_elements(v_items) e
     WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'producto_id', '') IS NOT NULL
     GROUP BY 1
     ORDER BY 1
$q$,
$q$    SELECT NULLIF(e->>'producto_id', '')::bigint AS producto,
           COALESCE((e->>'_sin_escala')::boolean, false) AS sin_escala,
           min(NULLIF(e->>'precio_unitario', '')::numeric) AS precio,
           max(NULLIF(e->>'precio_unitario', '')::numeric) AS precio_max,
           bool_or(NULLIF(e->>'precio_unitario', '') IS NULL) AS sin_precio,
           -- #1191: el precio sin escalas que declara un combo acumulable.
           max(NULLIF(e->>'precio_sin_escala_unitario', '')::numeric)
             FILTER (WHERE NULLIF(e->>'combo_id', '') IS NOT NULL) AS lista_combo_max
      FROM jsonb_array_elements(v_items) e
     WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
       AND NULLIF(e->>'producto_id', '') IS NOT NULL
     GROUP BY 1, 2
     ORDER BY 1, 2
$q$, 'politica: el bucle por producto');

  v_def := pg_temp.rr_parchar(v_def,
$q$    v_piso := public.precio_piso_linea(v_items, v_grupos, r.producto, v_lista, v_cliente, v_prod.categoria);
$q$,
$q$    -- #1191: sin las unidades de combos excluyentes en el conteo, y sin
    -- escala para ellas.
    v_piso := public.precio_piso_linea(v_items_escala,
                                       CASE WHEN r.sin_escala THEN '[]'::jsonb ELSE v_grupos END,
                                       r.producto, v_lista, v_cliente, v_prod.categoria);
$q$, 'politica: el piso');

  v_def := pg_temp.rr_parchar(v_def,
$q$      SELECT min(pi.precio_unitario), max(pi.precio_unitario) INTO v_guardado, v_guardado_max
$q$,
$q$      -- #1191: una linea de combo guardada vale por su precio sin combo.
      SELECT min(COALESCE(pi.precio_sin_combo_unitario, pi.precio_unitario)),
             max(COALESCE(pi.precio_sin_combo_unitario, pi.precio_unitario))
        INTO v_guardado, v_guardado_max
$q$, 'politica: el precio guardado');

  v_def := pg_temp.rr_parchar(v_def,
$q$                         FROM jsonb_array_elements(v_items) e
                        WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
                        GROUP BY 1) n
$q$,
$q$                         FROM jsonb_array_elements(v_items_escala) e
                        WHERE NOT COALESCE((e->>'es_bonificacion')::boolean, false)
                        GROUP BY 1) n
$q$, 'politica: el grupo nuevo');

  v_def := pg_temp.rr_parchar(v_def,
$q$                        WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                          AND NOT COALESCE(pi.es_bonificacion, false)
                        GROUP BY 1) o
$q$,
$q$                        WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal
                          AND NOT COALESCE(pi.es_bonificacion, false)
                          -- #1191: lo guardado en un combo excluyente no contaba.
                          AND NOT EXISTS (SELECT 1 FROM pedido_combos f
                                           WHERE f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_id
                                             AND f.sucursal_id = pi.sucursal_id AND NOT f.combina_escalas)
                        GROUP BY 1) o
$q$, 'politica: el grupo guardado');

  v_def := pg_temp.rr_parchar(v_def,
$q$                    to_char(v_techo, 'FM$999G999G990D00'));
    END IF;
  END LOOP;
$q$,
$q$                    to_char(v_techo, 'FM$999G999G990D00'));
    END IF;

    -- #1191: en un combo acumulable, el precio sin escalas que declara la
    -- linea (de ahi sale lo que el combo descuenta encima de la escala) no pasa
    -- la lista con el descuento del cliente.
    IF r.lista_combo_max IS NOT NULL THEN
      v_techo_sin_escala := public.precio_piso_linea(v_items_escala, '[]'::jsonb, r.producto,
                                                     v_techo, v_cliente, v_prod.categoria);
      IF v_techo_sin_escala IS NULL OR r.lista_combo_max > v_techo_sin_escala + 0.01 THEN
        RETURN format('El precio sin escalas de %s en el combo (%s) está por encima de la lista (%s). Solo un admin puede cargar otro precio.',
                      v_prod.nombre,
                      to_char(r.lista_combo_max, 'FM$999G999G990D00'),
                      COALESCE(to_char(v_techo_sin_escala, 'FM$999G999G990D00'), 'sin lista'));
      END IF;
    END IF;
  END LOOP;
$q$, 'politica: el techo sin escalas del acumulable');

  EXECUTE v_def;
END
$politica$;

-- -------------------------------------------------------------------------
-- 9 · crear_pedido_completo
-- -------------------------------------------------------------------------
DO $crear$
DECLARE
  v_def text := pg_get_functiondef(
    'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure);
BEGIN
  -- Un vale blanco no lleva combos (lo precia el server a costo).
  v_def := pg_temp.rr_parchar(v_def,
$q$                   OR NULLIF(e->>'promocion_id', '') IS NOT NULL) THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Un vale blanco no lleva promociones ni regalos.'));
$q$,
$q$                   OR NULLIF(e->>'promocion_id', '') IS NOT NULL
                   OR NULLIF(e->>'combo_id', '') IS NOT NULL) THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        'Un vale blanco no lleva promociones, combos ni regalos.'));
$q$, 'crear: el vale blanco sin combos');

  v_def := pg_temp.rr_parchar(v_def,
$q$  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
$q$,
$q$  -- #1191: los combos, para todo rol (estructura); para quien no es admin
  -- ademas vigencia, tope y el total y el reparto exactos. Antes de toda
  -- escritura. El codigo deja al front y al replay offline distinguirlo.
  IF p_items IS NOT NULL AND jsonb_typeof(p_items) = 'array' THEN
    DECLARE
      v_motivo_combo TEXT;
    BEGIN
      v_motivo_combo := public.combo_fuera_de_regla(p_items, v_sucursal, v_fecha_pedido, NULL,
                                                    v_user_role <> 'admin');
      IF v_motivo_combo IS NOT NULL THEN
        RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
          v_motivo_combo || ' El pedido no se creó.'), 'codigo', 'combo_fuera_de_regla');
      END IF;
    END;
  END IF;

  IF p_preventista_id IS NULL OR p_preventista_id = p_usuario_id THEN
$q$, 'crear: la validacion de combos');

  v_def := pg_temp.rr_parchar(v_def,
$q$      sucursal_id, descripcion_regalo, stock_al_crear, costo_unitario_al_crear,
      origen_precio, regalo_cadena_id
    ) VALUES (
$q$,
$q$      sucursal_id, descripcion_regalo, stock_al_crear, costo_unitario_al_crear,
      origen_precio, regalo_cadena_id, combo_id, precio_sin_combo_unitario
    ) VALUES (
$q$, 'crear: columnas del INSERT');

  v_def := pg_temp.rr_parchar(v_def,
$q$      CASE WHEN v_tipo_factura = 'VB' THEN 'costo_interno' END, v_cadena_alta
    ) RETURNING id INTO v_item_id;
$q$,
$q$      CASE WHEN v_tipo_factura = 'VB' THEN 'costo_interno' END, v_cadena_alta,
      -- #1191: validados arriba por combo_fuera_de_regla.
      NULLIF(item->>'combo_id', '')::BIGINT,
      CASE WHEN NULLIF(item->>'combo_id', '') IS NOT NULL
           THEN NULLIF(item->>'precio_sin_combo_unitario', '')::NUMERIC END
    ) RETURNING id INTO v_item_id;
$q$, 'crear: valores del INSERT');

  v_def := pg_temp.rr_parchar(v_def,
$q$  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2),
$q$,
$q$  -- #1191: la foto de los combos del pedido.
  PERFORM public._guardar_combos_pedido(v_pedido_id, v_sucursal);

  UPDATE pedidos
     SET total_neto = round(v_total_neto_calc, 2),
$q$, 'crear: la foto');

  EXECUTE v_def;
END
$crear$;

-- -------------------------------------------------------------------------
-- 10 · actualizar_pedido_items
-- -------------------------------------------------------------------------
DO $editar$
DECLARE
  v_def text := pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$  v_cant_invalida TEXT;
BEGIN
$q$,
$q$  v_cant_invalida TEXT;
  -- #1191: los productos de venta ya comparados en el pre-chequeo de stock.
  v_productos_vistos INT[] := '{}';
BEGIN
$q$, 'editar: declaraciones');

  v_def := pg_temp.rr_parchar(v_def,
$q$  -- mig 313 (#996): con la descripcion de cada linea y en un orden que no
$q$,
$q$  -- #1191: los combos, tambien al editar y para todo rol (estructura); para
  -- quien no es admin ademas vigencia, tope y el total y el reparto exactos.
  -- Un combo que el pedido ya tenia se mide contra su foto (pedido_combos).
  DECLARE
    v_motivo_combo TEXT;
  BEGIN
    v_motivo_combo := public.combo_fuera_de_regla(
      v_items, v_sucursal,
      (SELECT fecha FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal),
      p_pedido_id, v_user_role <> 'admin');
    IF v_motivo_combo IS NOT NULL THEN
      RETURN jsonb_build_object('success', false, 'errores', jsonb_build_array(
        v_motivo_combo || ' El pedido no se modificó.'), 'codigo', 'combo_fuera_de_regla');
    END IF;
  END;

  -- mig 313 (#996): con la descripcion de cada linea y en un orden que no
$q$, 'editar: la validacion de combos');

  v_def := pg_temp.rr_parchar(v_def,
$q$    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);
$q$,
$q$    -- #1191: un producto puede venir en dos lineas de venta (la del combo y
    -- la suelta). Se compara la suma del producto, una sola vez: el SELECT de
    -- arriba tomaba una linea cualquiera.
    IF NOT v_es_bonificacion THEN
      IF v_producto_id = ANY(v_productos_vistos) THEN
        CONTINUE;
      END IF;
      v_productos_vistos := v_productos_vistos || v_producto_id;
      SELECT COALESCE(SUM((e->>'cantidad')::INT), 0) INTO v_cantidad_nueva
        FROM jsonb_array_elements(v_items) e
       WHERE NOT COALESCE((e->>'es_bonificacion')::BOOLEAN, false)
         AND (e->>'producto_id')::INT = v_producto_id;
      SELECT COALESCE(SUM(cantidad), 0) INTO v_cantidad_original
        FROM pedido_items
       WHERE pedido_id = p_pedido_id AND producto_id = v_producto_id
         AND NOT COALESCE(es_bonificacion, false) AND sucursal_id = v_sucursal;
    END IF;

    v_diferencia := v_cantidad_nueva - COALESCE(v_cantidad_original, 0);
$q$, 'editar: el pre-chequeo de stock por producto');

  v_def := pg_temp.rr_parchar(v_def,
$q$      sucursal_id, descripcion_regalo, costo_unitario_al_crear, regalo_cadena_id
    ) VALUES (
$q$,
$q$      sucursal_id, descripcion_regalo, costo_unitario_al_crear, regalo_cadena_id,
      combo_id, precio_sin_combo_unitario
    ) VALUES (
$q$, 'editar: columnas del INSERT');

  v_def := pg_temp.rr_parchar(v_def,
$q$      CASE WHEN v_es_bonificacion AND v_promocion_id IS NOT NULL
           THEN (v_item_nuevo->>'_cadena')::UUID END
    )
$q$,
$q$      CASE WHEN v_es_bonificacion AND v_promocion_id IS NOT NULL
           THEN (v_item_nuevo->>'_cadena')::UUID END,
      -- #1191: validados arriba por combo_fuera_de_regla.
      NULLIF(v_item_nuevo->>'combo_id', '')::BIGINT,
      CASE WHEN NULLIF(v_item_nuevo->>'combo_id', '') IS NOT NULL
           THEN NULLIF(v_item_nuevo->>'precio_sin_combo_unitario', '')::NUMERIC END
    )
$q$, 'editar: valores del INSERT');

  v_def := pg_temp.rr_parchar(v_def,
$q$  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2)$q$,
$q$  -- #1191: la foto de los combos del pedido (conserva la de los que ya tenia).
  PERFORM public._guardar_combos_pedido(p_pedido_id, v_sucursal);

  UPDATE pedidos SET total = v_total_nuevo, total_neto = round(v_total_neto_nuevo, 2)$q$, 'editar: la foto');

  EXECUTE v_def;
END
$editar$;

-- -------------------------------------------------------------------------
-- 11 · La huella por linea: combo_id es parte de la identidad de la linea
-- -------------------------------------------------------------------------
DO $huella$
DECLARE
  v_foto    text := pg_get_functiondef('public._foto_huella_lineas(bigint[])'::regprocedure);
  v_rehacer text := pg_get_functiondef('public._rehacer_huella_lineas(jsonb,bigint[])'::regprocedure);
BEGIN
  v_foto := pg_temp.rr_parchar(v_foto,
$q$             || '|' || COALESCE(pi.regalo_cadena_id::text, '') AS clave
$q$,
$q$             || '|' || COALESCE(pi.regalo_cadena_id::text, '')
             -- #1191: la linea del combo y la suelta del mismo producto.
             || '|' || COALESCE(pi.combo_id::text, '') AS clave
$q$, 'huella: la clave de la foto');

  v_rehacer := pg_temp.rr_parchar(v_rehacer,
$q$|| '|' || COALESCE(pi.regalo_cadena_id::text, '') = c->>'clave';$q$,
$q$|| '|' || COALESCE(pi.regalo_cadena_id::text, '')
               || '|' || COALESCE(pi.combo_id::text, '') = c->>'clave';$q$, 'huella: la clave al contar');

  v_rehacer := pg_temp.rr_parchar(v_rehacer,
$q$|| '|' || COALESCE(pi.regalo_cadena_id::text, '') = c->>'clave'
           ORDER BY pi.id$q$,
$q$|| '|' || COALESCE(pi.regalo_cadena_id::text, '')
                   || '|' || COALESCE(pi.combo_id::text, '') = c->>'clave'
           ORDER BY pi.id$q$, 'huella: la clave al anotar');

  v_rehacer := pg_temp.rr_parchar(v_rehacer,
$q$         ORDER BY (COALESCE(pi.es_bonificacion, false) = v_bonif[i]
$q$,
$q$         ORDER BY (COALESCE(pi.es_bonificacion, false)::text || '|' || COALESCE(pi.promocion_id::text, '')
                   || '|' || COALESCE(pi.regalo_cadena_id::text, '')
                   || '|' || COALESCE(pi.combo_id::text, '')) = v_clave[i] DESC,
                  (COALESCE(pi.es_bonificacion, false) = v_bonif[i]
$q$, 'huella: el sobrante prefiere su misma linea');

  EXECUTE v_foto;
  EXECUTE v_rehacer;
END
$huella$;

-- -------------------------------------------------------------------------
-- 12 · Un pedido con combos no pasa a vale blanco
-- -------------------------------------------------------------------------
DO $tipo$
DECLARE
  v_oid oid := (SELECT oid FROM pg_proc
                 WHERE proname = 'cambiar_tipo_factura_pedido' AND pronamespace = 'public'::regnamespace);
  v_def text := pg_get_functiondef(v_oid);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$                    AND (COALESCE(es_bonificacion, false) OR promocion_id IS NOT NULL)) THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene promociones o regalos: un vale blanco no los lleva');$q$,
$q$                    AND (COALESCE(es_bonificacion, false) OR promocion_id IS NOT NULL
                         OR combo_id IS NOT NULL)) THEN
        RETURN jsonb_build_object('success', false, 'error',
          'El pedido tiene promociones, combos o regalos: un vale blanco no los lleva');$q$,
    'tipo: el vale blanco sin combos');
  EXECUTE v_def;
END
$tipo$;

-- -------------------------------------------------------------------------
-- 13 · COMBO-A en auditoria_integridad
-- -------------------------------------------------------------------------
DO $audit$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_integridad()'::regprocedure);
BEGIN
  v_def := pg_temp.rr_parchar(v_def,
$q$
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$q$,
$q$,
    -- #1191 · cada linea de combo de un pedido vivo tiene su foto, su producto
    -- es de un lugar del combo y la suma del lugar no pasa de k x su cantidad
    -- (una salvedad puede bajarla, nunca subirla).
    ('COMBO-A','high','líneas de combo coherentes con la foto del pedido (#1191)',
      (SELECT count(*) FROM pedido_items pi
         JOIN pedidos p ON p.id = pi.pedido_id AND p.sucursal_id = pi.sucursal_id
         LEFT JOIN pedido_combos f
           ON f.pedido_id = pi.pedido_id AND f.combo_id = pi.combo_id AND f.sucursal_id = pi.sucursal_id
         LEFT JOIN LATERAL (SELECT c FROM jsonb_array_elements(f.componentes) c
                             WHERE c->'productos' @> to_jsonb(pi.producto_id) LIMIT 1) lug ON true
        WHERE pi.combo_id IS NOT NULL AND p.estado NOT IN ('cancelado','anulado')
          AND (f.pedido_id IS NULL OR lug.c IS NULL
               OR (SELECT COALESCE(sum(pj.cantidad), 0) FROM pedido_items pj
                    WHERE pj.pedido_id = pi.pedido_id AND pj.combo_id = pi.combo_id
                      AND lug.c->'productos' @> to_jsonb(pj.producto_id))
                  > f.cantidad_combos * (lug.c->>'cantidad')::int)))
  )
  SELECT jsonb_agg(
    jsonb_build_object('id',id,'severidad',severidad,'descripcion',descripcion,'violaciones',viol,'ok',(viol=0))$q$,
    'auditoria: COMBO-A');
  EXECUTE v_def;
END
$audit$;

-- -------------------------------------------------------------------------
-- 14 · Verificacion estructural
-- -------------------------------------------------------------------------
DO $verif$
DECLARE
  f text;
BEGIN
  -- Las de server, invisibles para el front.
  FOREACH f IN ARRAY ARRAY[
    'public._combo_prorrateo(numeric,jsonb)', 'public._combo_total(numeric,integer,jsonb)',
    'public._combo_cantidad(jsonb,jsonb)', 'public._combo_definicion(bigint,bigint)',
    'public.combo_fuera_de_regla(jsonb,bigint,date,bigint,boolean)', 'public._guardar_combos_pedido(bigint,bigint)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION '% quedo alcanzable desde el front', f;
    END IF;
  END LOOP;
  -- Las del front, sin anon.
  FOREACH f IN ARRAY ARRAY['public.combos_vigentes(date,bigint)', 'public.guardar_combo(jsonb)'] LOOP
    IF has_function_privilege('anon', f, 'EXECUTE') OR NOT has_function_privilege('authenticated', f, 'EXECUTE') THEN
      RAISE EXCEPTION 'los EXECUTE de % no quedaron como se esperaba', f;
    END IF;
  END LOOP;
  -- Las tablas: RLS, sin escritura REST, sin anon.
  FOREACH f IN ARRAY ARRAY['public.combos', 'public.combo_componentes', 'public.pedido_combos'] LOOP
    IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = f::regclass) THEN
      RAISE EXCEPTION '% sin RLS', f;
    END IF;
    IF has_table_privilege('anon', f, 'SELECT')
       OR has_table_privilege('authenticated', f, 'INSERT') OR has_table_privilege('authenticated', f, 'UPDATE')
       OR has_table_privilege('authenticated', f, 'DELETE') THEN
      RAISE EXCEPTION '% quedo con privilegios de mas', f;
    END IF;
  END LOOP;
  IF NOT has_column_privilege('authenticated', 'public.pedido_items', 'combo_id', 'SELECT')
     OR NOT has_column_privilege('authenticated', 'public.pedido_items', 'precio_sin_combo_unitario', 'SELECT') THEN
    RAISE EXCEPTION 'las columnas nuevas de pedido_items no se leen';
  END IF;
  -- Los llamadores.
  IF position('combo_fuera_de_regla' IN pg_get_functiondef(
       'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure)) = 0
     OR position('_guardar_combos_pedido' IN pg_get_functiondef(
       'public.crear_pedido_completo(bigint,numeric,uuid,jsonb,text,text,text,date,text,numeric,numeric,date,uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'crear_pedido_completo no quedo como se esperaba';
  END IF;
  IF position('combo_fuera_de_regla' IN pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure)) = 0
     OR position('_guardar_combos_pedido' IN pg_get_functiondef('public.actualizar_pedido_items(bigint,jsonb,uuid)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'actualizar_pedido_items no quedo como se esperaba';
  END IF;
  IF position('_sin_escala' IN pg_get_functiondef('public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'precio_fuera_de_politica no quedo como se esperaba';
  END IF;
  -- La politica sigue siendo invoker STABLE, de server (369).
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)'::regprocedure)
     OR (SELECT provolatile FROM pg_proc WHERE oid = 'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)'::regprocedure) <> 's'
     OR has_function_privilege('authenticated', 'public.precio_fuera_de_politica(jsonb,bigint,bigint,bigint)', 'EXECUTE') THEN
    RAISE EXCEPTION 'precio_fuera_de_politica cambio de forma o de permisos';
  END IF;
  -- Las puras dan lo del fixture en los casos de la cabecera.
  IF public._combo_prorrateo(14000, '[{"producto_id":2,"cantidad":2,"ref":2500},{"producto_id":1,"cantidad":1,"ref":10000}]')
       IS DISTINCT FROM '{"1": 9333.34, "2": 2333.33}'::jsonb
     OR public._combo_total(11000, 1, '[{"producto_id":1,"cantidad":1,"ref":10000,"sin_escala":10000},{"producto_id":2,"cantidad":1,"ref":2000,"sin_escala":2500}]') <> 10500
     OR public._combo_cantidad('[{"componente":1,"cantidad":2,"productos":[2]},{"componente":2,"cantidad":1,"productos":[1]}]',
                               '[{"producto_id":2,"cantidad":4},{"producto_id":1,"cantidad":2}]') <> 2 THEN
    RAISE EXCEPTION 'las puras de combos no dan lo esperado';
  END IF;
END
$verif$;

COMMIT;
