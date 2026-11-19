-- =========================================================================
-- NNN · CATÁLOGO: GUARDAR EN UNA SOLA OPERACIÓN, Y «OTRO LO CAMBIÓ MIENTRAS
--       LO EDITABAS» EN COMBOS Y PROMOS
--       (tarjeta C4b de la tanda 5 de la ola 2 de #1603: 1561-b12 de #1561,
--        1599-b8 de #1599 y 1598-b5 de #1598)
--
-- Hasta acá el front guardaba en varios pasos REST y compensaba si uno fallaba
-- (#1630, #1637): la condición mayorista con sus productos, escalas y mínimos
-- (unas diez llamadas), el alta de una promo (tres INSERT), los roles extra de
-- un usuario (`perfil_roles`) y los descuentos por categoría de un cliente.
-- Si fallaban el paso y la compensación, quedaba algo a medias (una condición
-- sin escalas, una promo sin reglas, un cliente sin sus descuentos). Cada uno
-- pasa a UNA RPC, en una transacción: o entra todo o no entra nada.
--
--   · `guardar_condicion_mayorista(jsonb)`: alta y edición de la condición
--     entera. En la edición concilia (no borra para volver a insertar): las
--     escalas por cantidad mínima conservan su id (lo guarda `pedido_items`,
--     mig 148) y los mínimos por producto se escriben con upsert.
--   · `crear_promocion(jsonb)`: el alta de la promo con sus productos y sus
--     reglas. La edición ya era una RPC (`cambiar_regalo_promocion`, #1491).
--   · `guardar_roles_extra(uuid, text[])`: deja los roles extra del usuario en
--     la sucursal activa como pide la ficha.
--   · `guardar_descuentos_categoria(bigint, jsonb)`: deja los descuentos por
--     categoría del cliente como pide la ficha.
--
-- Las cuatro son SECURITY DEFINER y validan adentro lo mismo que hoy validan
-- las policies, las restricciones de las tablas y el formulario:
--   · condición y promo: `es_admin()` (que ya mira `activo`) y la sucursal
--     activa, como `mt_grupos_precio_all` y `mt_promociones_all`; los productos
--     de la sucursal; y las reglas del formulario (al menos un producto y una
--     escala, cantidades distintas, la escala combinada alcanzable; en la promo
--     las dos reglas, el regalo o el contenedor según el tipo).
--   · roles: `es_admin()`, la sucursal activa, `admin_abarca_sucursales_de` y
--     que el usuario sea de la sucursal, como `perfil_roles_write_admin`.
--   · descuentos: `es_admin()` y `cliente_de_sucursal_activa`, como
--     `cdc_insert` / `cdc_delete`; el porcentaje de 0 a 100.
-- Las dos altas (condición y promo) piden una clave (`clave`, un uuid por
-- formulario abierto): un reintento después de una respuesta perdida no crea
-- otra, devuelve la misma (`replay`). Con la misma clave y otro contenido se
-- rechaza con el motivo (el primer intento ya la creó). Las claves viven en
-- `altas_por_clave`, que es sólo de server (RLS sin policies, sin grants). Las
-- otras dos dejan el estado pedido: repetirlas no cambia nada.
--
-- No se revoca ningún grant REST: los bundles viejos del PWA siguen
-- escribiendo por REST hasta que no queden (las escrituras que el front de hoy
-- deja de usar pasan a `bundle_viejo` de scripts/grants-rest.json).
--
-- Control de versión (1599-b8; el molde es la edición de un gasto, 1599-b9):
--   · `guardar_combo` recibe en el JSON `updated_at_esperado` (el `updated_at`
--     del combo al abrirlo) y `versiones` (el de cada combo del orden que
--     reescribe). Si otro guardó el combo, o reordenó o cambió uno del grupo,
--     no escribe nada y devuelve `codigo` 'combo_cambiado' u 'orden_cambiado'.
--     Toma el combo y los del orden FOR UPDATE, por id, antes de comparar. Y al
--     reordenar les mueve el `updated_at` a los que cambian de prioridad: es un
--     cambio suyo. Sin las claves (un PWA de antes) no compara.
--   · `cambiar_regalo_promocion` recibe `updated_at_esperado` dentro de
--     `p_datos` y devuelve `codigo` 'promocion_cambiada'. Sin cambiar la firma.
--   · `update_promociones_updated_at` (el trigger de la versión de la promo)
--     ya no la mueve cuando el UPDATE sólo cambia `usos_pendientes`: la barra
--     de regalos de fracción la escribe en cada venta, y con eso cualquier
--     venta en el medio parecía «otro la cambió». Una UPDATE que no cambia nada
--     tampoco la mueve. Nadie lee `promociones.updated_at` para otra cosa.
--
-- Funciones parchadas por ancla, con premisa de md5 (cuerpo en LF) sobre el
-- vivo de la 530: `guardar_combo(jsonb)` y
-- `cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)`. Reemplazada
-- entera: `update_promociones_updated_at()`. Y una línea en la lista de PROMO-C
-- (`auditoria_funciones_modo_regalo_vivo`, por ancla y sin premisa: el alta de
-- una promo escribe `regalo_mueve_stock` sin pedidos). Ninguna cambia de firma. Todas las
-- definer de esta migración quedan con `pg_temp` al final del search_path
-- (regla de B15), y también el trigger reemplazado. Y `guardar_combo` deja de
-- reusar una temporal `_combo_resuelto` de quien llama (hallazgo de B15): la tira y
-- la crea calificada. No hay DDL sobre tablas existentes: no hace falta LOCK.
--
-- Ensayo: scripts/test-guardados-atomicos-ola2-1603.sql. Se aplica en LF.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';

-- La única tabla que se altera (la columna de la versión y su trigger, v2): de una vez y antes de
-- toda premisa. O se consigue o falla al instante y se reintenta.
LOCK TABLE public.clientes IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos de la 530 (conc-base:530), normalizados a LF.
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.guardar_combo(jsonb)', 'c425454c628f7dbf2c2dd60140ce196f'),
    ('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)', '582dae61b953871c538470ccd69ce394'),
    ('public.update_promociones_updated_at()', 'da5ac28a58c8b4bb30209bf0d3d7082c'),
    -- No cambian: las RPC nuevas cuentan con ellas como están.
    ('public.es_admin()', '975886be1dc20e67edba71686ef50959'),
    ('public.admin_abarca_sucursales_de(uuid)', 'fa0ee154b1c1c5a35245ea0746ad0c7e'),
    ('public.cliente_de_sucursal_activa(bigint)', 'f40cb2ef4e2c451a601d2030ec6196d8'),
    -- v2: guardar_cliente y guardar_usuario corren como quien llama (INVOKER) y cuentan con que
    -- estas guardas de clientes, cliente_preventistas y perfiles sigan como en la 530.
    ('public.verificar_duplicado_cliente(numeric,numeric,text,bigint)', '3f95ea7d1843c7dade9bbc84baf50dd9'),
    ('public._cliente_visible(bigint,bigint,boolean)', '7698df4ccb647b9760d60efca9ac4437'),
    ('public.perfiles_guard_desactivacion()', 'e5f88a02905ba3dc4118db7fb8ef39de')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(replace(prosrc, E'\r\n', E'\n')) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 en LF %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  IF to_regclass('public.altas_por_clave') IS NOT NULL
     OR to_regprocedure('public.guardar_condicion_mayorista(jsonb)') IS NOT NULL
     OR to_regprocedure('public.crear_promocion(jsonb)') IS NOT NULL
     OR to_regprocedure('public.guardar_roles_extra(uuid,text[])') IS NOT NULL
     OR to_regprocedure('public.guardar_descuentos_categoria(bigint,jsonb)') IS NOT NULL
     OR to_regprocedure('public.guardar_cliente(jsonb)') IS NOT NULL
     OR to_regprocedure('public.guardar_usuario(jsonb)') IS NOT NULL
     OR to_regprocedure('public._alta_cliente_tomar_clave(uuid,text)') IS NOT NULL
     OR to_regprocedure('public._alta_cliente_cerrar_clave(uuid,bigint)') IS NOT NULL
     OR to_regprocedure('public.clientes_version()') IS NOT NULL
     OR EXISTS (SELECT 1 FROM information_schema.columns
                 WHERE table_schema = 'public' AND table_name = 'clientes' AND column_name = 'updated_at') THEN
    RAISE EXCEPTION 'mig NNN · alguno de los objetos nuevos ya existe';
  END IF;
  -- Una sola firma de cada una (trampa 5: nada de sobrecargas).
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('guardar_combo', 'cambiar_regalo_promocion')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · guardar_combo o cambiar_regalo_promocion tiene más de una firma';
  END IF;
  -- La conciliación usa estas restricciones como claves.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.grupo_precio_escalas'::regclass
                   AND conname = 'grupo_precio_escalas_grupo_precio_id_cantidad_minima_key')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.grupo_precio_escala_minimos'::regclass
                   AND conname = 'grupo_precio_escala_minimos_pkey'
                   AND pg_get_constraintdef(oid) = 'PRIMARY KEY (escala_id, producto_id)')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.perfil_roles'::regclass
                   AND conname = 'perfil_roles_uq')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.cliente_descuentos_categoria'::regclass
                   AND conname = 'cliente_descuentos_categoria_cliente_id_categoria_key')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conrelid = 'public.perfil_roles'::regclass
                   AND conname = 'perfil_roles_rol_check'
                   AND pg_get_constraintdef(oid) = 'CHECK ((rol = ''transportista''::text))') THEN
    RAISE EXCEPTION 'mig NNN · las restricciones de las tablas no son las que se leyeron en la 530';
  END IF;
END
$premisas$;

-- Reemplaza una sola aparición de un ancla. El cuerpo puede estar en LF o en CRLF: el ancla se
-- busca como viene y, si no aparece, con CRLF; el texto nuevo entra con el mismo fin de línea.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_ancla text := p_ancla;
  v_nuevo text := p_nuevo;
  v_n int := (length(p_def) - length(replace(p_def, p_ancla, ''))) / length(p_ancla);
BEGIN
  IF v_n = 0 AND position(E'\r\n' in p_def) > 0 THEN
    v_ancla := replace(p_ancla, E'\n', E'\r\n');
    v_nuevo := replace(p_nuevo, E'\n', E'\r\n');
    v_n := (length(p_def) - length(replace(p_def, v_ancla, ''))) / length(v_ancla);
  END IF;
  IF v_n <> 1 THEN
    RAISE EXCEPTION 'mig NNN · %: el ancla aparece % vez/veces y se esperaba 1', p_que, v_n;
  END IF;
  RETURN replace(p_def, v_ancla, v_nuevo);
END
$f$;

-- =========================================================================
-- 1 · Las claves de las altas
-- =========================================================================
CREATE TABLE public.altas_por_clave (
  clave       uuid        PRIMARY KEY,
  operacion   text        NOT NULL CHECK (operacion IN ('condicion_mayorista', 'promocion', 'cliente')),
  usuario_id  uuid        NOT NULL,
  sucursal_id bigint      NOT NULL,
  contenido   text        NOT NULL,
  entidad_id  bigint,
  created_at  timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.altas_por_clave IS
  'C4b (ola 2 de #1603): la clave de cada alta de condición mayorista, de promo o de cliente, para que un reintento después de una respuesta perdida devuelva la misma y no cree otra. `contenido` es el md5 del JSON pedido sin la clave: con la misma clave y otro contenido se rechaza. Sólo de server: RLS sin policies y sin grants para anon ni authenticated. La escriben guardar_condicion_mayorista y crear_promocion, y la del cliente _alta_cliente_tomar_clave / _alta_cliente_cerrar_clave (guardar_cliente corre como quien llama).';

ALTER TABLE public.altas_por_clave ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.altas_por_clave FROM PUBLIC, anon, authenticated;

-- =========================================================================
-- 2 · La condición mayorista entera, en una transacción
-- =========================================================================
CREATE FUNCTION public.guardar_condicion_mayorista(p_condicion jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_suc       bigint := public.current_sucursal_id();
  v_id        bigint;
  v_clave     uuid;
  v_nombre    text;
  v_desc      text;
  v_prods     bigint[];
  v_esc       jsonb;
  v_norm      jsonb := '[]'::jsonb;
  v_r         record;
  v_m         record;
  v_cant      bigint;
  v_precio    numeric;
  v_k         bigint;
  v_etiq      text;
  v_mins      jsonb;
  v_min_prods bigint[];
  v_min_cants integer[];
  v_cants     integer[] := '{}';
  v_mcant     bigint;
  v_over      numeric;
  v_previa    public.altas_por_clave%ROWTYPE;
  v_contenido text;
  v_x         bigint;
  v_lock      bigint[];
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin crea o edita condiciones mayoristas.' USING ERRCODE = '42501';
  END IF;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_condicion) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos de la condición.' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_id     := NULLIF(p_condicion->>'id', '')::bigint;
    v_clave  := NULLIF(p_condicion->>'clave', '')::uuid;
    v_nombre := btrim(COALESCE(p_condicion->>'nombre', ''));
    v_desc   := NULLIF(btrim(COALESCE(p_condicion->>'descripcion', '')), '');
    IF jsonb_typeof(p_condicion->'producto_ids') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_condicion->'escalas') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION USING ERRCODE = '22P02';
    END IF;
    SELECT COALESCE(array_agg(DISTINCT (e #>> '{}')::bigint), '{}') INTO v_prods
      FROM jsonb_array_elements(p_condicion->'producto_ids') e;
    v_esc := p_condicion->'escalas';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato de la condición con un formato inválido.' USING ERRCODE = '22023';
  END;

  IF v_nombre = '' THEN
    RAISE EXCEPTION 'La condición necesita un nombre.' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_prods) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para la condición.' USING ERRCODE = '22023';
  END IF;
  IF EXISTS (SELECT 1 FROM unnest(v_prods) x
              WHERE NOT EXISTS (SELECT 1 FROM productos p WHERE p.id = x AND p.sucursal_id = v_suc)) THEN
    RAISE EXCEPTION 'Hay un producto de la condición que no es de esta sucursal.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(v_esc) = 0 THEN
    RAISE EXCEPTION 'La condición necesita al menos una escala de precio.' USING ERRCODE = '22023';
  END IF;

  -- Cada escala, validada y normalizada (las mismas reglas que ModalGrupoPrecio).
  FOR v_r IN SELECT e FROM jsonb_array_elements(v_esc) AS t(e) LOOP
    IF jsonb_typeof(v_r.e) IS DISTINCT FROM 'object'
       OR jsonb_typeof(v_r.e->'cantidad_minima') IS DISTINCT FROM 'number'
       OR jsonb_typeof(v_r.e->'precio_unitario') IS DISTINCT FROM 'number'
       OR jsonb_typeof(COALESCE(v_r.e->'min_productos_distintos', '1'::jsonb)) IS DISTINCT FROM 'number'
       OR jsonb_typeof(COALESCE(v_r.e->'minimos', '[]'::jsonb)) IS DISTINCT FROM 'array'
       OR jsonb_typeof(COALESCE(v_r.e->'etiqueta', 'null'::jsonb)) NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'Hay una escala de la condición con un formato inválido.' USING ERRCODE = '22023';
    END IF;
    v_cant := NULL; v_k := NULL;
    IF (v_r.e->>'cantidad_minima') ~ '^[0-9]{1,10}$' THEN v_cant := (v_r.e->>'cantidad_minima')::bigint; END IF;
    IF COALESCE(v_r.e->>'min_productos_distintos', '1') ~ '^[0-9]{1,10}$' THEN
      v_k := COALESCE(v_r.e->>'min_productos_distintos', '1')::bigint;
    END IF;
    IF v_cant IS NULL OR v_cant < 1 OR v_cant > 2147483647 THEN
      RAISE EXCEPTION 'Las cantidades mínimas de las escalas tienen que ser enteros mayores a 0.' USING ERRCODE = '22023';
    END IF;
    v_precio := round((v_r.e->>'precio_unitario')::numeric, 2);
    IF NOT (v_precio > 0 AND v_precio <= 9999999999.99) THEN
      RAISE EXCEPTION 'Escala de % u.: el precio tiene que ser mayor a 0.', v_cant USING ERRCODE = '22023';
    END IF;
    IF v_k IS NULL OR v_k < 1 OR v_k > 2147483647 THEN
      RAISE EXCEPTION 'Escala de % u.: el mínimo de productos distintos tiene que ser un entero mayor a 0.', v_cant USING ERRCODE = '22023';
    END IF;
    v_etiq := NULLIF(btrim(COALESCE(v_r.e->>'etiqueta', '')), '');
    v_cants := v_cants || v_cant::integer;

    -- Los mínimos por producto de una escala combinada.
    v_mins := '[]'::jsonb; v_min_prods := '{}'; v_min_cants := '{}';
    FOR v_m IN SELECT m FROM jsonb_array_elements(COALESCE(v_r.e->'minimos', '[]'::jsonb)) AS t(m) LOOP
      IF jsonb_typeof(v_m.m) IS DISTINCT FROM 'object'
         OR COALESCE(jsonb_typeof(v_m.m->'producto_id'), 'null') NOT IN ('number', 'string')
         OR jsonb_typeof(v_m.m->'cantidad') IS DISTINCT FROM 'number'
         OR jsonb_typeof(COALESCE(v_m.m->'precio_override', 'null'::jsonb)) NOT IN ('number', 'null')
         OR COALESCE(v_m.m->>'producto_id', '') !~ '^[0-9]{1,18}$' THEN
        RAISE EXCEPTION 'Escala de % u.: hay un mínimo por producto con un formato inválido.', v_cant USING ERRCODE = '22023';
      END IF;
      v_x := (v_m.m->>'producto_id')::bigint;
      v_mcant := NULL;
      IF (v_m.m->>'cantidad') ~ '^[0-9]{1,10}$' THEN v_mcant := (v_m.m->>'cantidad')::bigint; END IF;
      IF NOT (v_x = ANY (v_prods)) THEN
        RAISE EXCEPTION 'Escala de % u.: hay un mínimo para un producto que no está en la condición.', v_cant USING ERRCODE = '22023';
      END IF;
      IF v_x = ANY (v_min_prods) THEN
        RAISE EXCEPTION 'Escala de % u.: un producto tiene dos mínimos.', v_cant USING ERRCODE = '22023';
      END IF;
      IF v_mcant IS NULL OR v_mcant < 1 OR v_mcant > 2147483647 THEN
        RAISE EXCEPTION 'Escala de % u.: el mínimo de cada producto tiene que ser un entero mayor a 0.', v_cant USING ERRCODE = '22023';
      END IF;
      v_over := round(NULLIF(v_m.m->>'precio_override', '')::numeric, 2);
      IF v_over IS NOT NULL AND NOT (v_over > 0 AND v_over <= 9999999999.99) THEN
        RAISE EXCEPTION 'Escala de % u.: el precio de un producto tiene que ser mayor a 0.', v_cant USING ERRCODE = '22023';
      END IF;
      v_min_prods := v_min_prods || v_x;
      v_min_cants := v_min_cants || v_mcant::integer;
      v_mins := v_mins || jsonb_build_object('producto', v_x, 'cantidad', v_mcant, 'override', v_over);
    END LOOP;

    -- Requiere combinación: al menos k productos con mínimo, y la suma de los k mínimos más bajos
    -- entra en la cantidad de la escala (si no, la regla es inalcanzable).
    IF v_k >= 2 THEN
      IF cardinality(v_min_prods) < v_k THEN
        RAISE EXCEPTION 'La escala de % u. requiere % productos distintos pero sólo % tienen mínimo configurado.',
          v_cant, v_k, cardinality(v_min_prods) USING ERRCODE = '22023';
      END IF;
      SELECT sum(c) INTO v_mcant FROM (SELECT c FROM unnest(v_min_cants) c ORDER BY c LIMIT v_k) s;
      IF v_mcant > v_cant THEN
        RAISE EXCEPTION 'Regla inalcanzable en la escala de % u.: sumando los % mínimos más bajos da %, que excede %.',
          v_cant, v_k, v_mcant, v_cant USING ERRCODE = '22023';
      END IF;
    END IF;

    v_norm := v_norm || jsonb_build_object('cantidad', v_cant, 'precio', v_precio, 'etiqueta', v_etiq,
                                           'k', v_k, 'minimos', v_mins);
  END LOOP;

  IF cardinality(v_cants) <> (SELECT count(DISTINCT c) FROM unnest(v_cants) c) THEN
    RAISE EXCEPTION 'No puede haber dos escalas con la misma cantidad mínima.' USING ERRCODE = '22023';
  END IF;

  IF v_id IS NULL THEN
    -- Alta: la clave del formulario. El reintento de la misma alta devuelve la que ya se creó.
    IF v_clave IS NULL THEN
      RAISE EXCEPTION 'Falta la clave del alta: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
    END IF;
    v_contenido := md5((p_condicion - 'clave')::text);
    INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
    VALUES (v_clave, 'condicion_mayorista', auth.uid(), v_suc, v_contenido)
    ON CONFLICT (clave) DO NOTHING;
    IF NOT FOUND THEN
      SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
      IF v_previa.operacion <> 'condicion_mayorista' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
         OR v_previa.sucursal_id <> v_suc THEN
        RAISE EXCEPTION 'Esta clave de alta ya se usó para otra operación: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
      END IF;
      IF v_previa.contenido <> v_contenido THEN
        RAISE EXCEPTION 'Esta condición ya se creó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y corregila desde la lista.' USING ERRCODE = '22023';
      END IF;
      IF NOT EXISTS (SELECT 1 FROM grupos_precio WHERE id = v_previa.entidad_id AND sucursal_id = v_suc) THEN
        RAISE EXCEPTION 'Esta condición ya se había creado con el intento anterior y después se eliminó: cerrá esta ventana y creala de nuevo.' USING ERRCODE = '22023';
      END IF;
      RETURN jsonb_build_object('id', v_previa.entidad_id, 'replay', true);
    END IF;
    v_lock := v_prods;
  ELSE
    -- Edición: los productos que entran (los nuevos y los de los mínimos) toman el KEY SHARE de
    -- la FK; van antes que la condición, como en la venta (productos y después lo demás).
    v_lock := ARRAY(SELECT x FROM unnest(v_prods) x
                     WHERE NOT EXISTS (SELECT 1 FROM grupo_precio_productos gp
                                        WHERE gp.grupo_precio_id = v_id AND gp.producto_id = x))
              || ARRAY(SELECT (m->>'producto')::bigint
                         FROM jsonb_array_elements(v_norm) n, jsonb_array_elements(n->'minimos') m);
  END IF;

  FOR v_x IN SELECT p.id FROM productos p
              WHERE p.sucursal_id = v_suc AND p.id = ANY (v_lock)
              ORDER BY p.id LOOP
    PERFORM 1 FROM productos WHERE id = v_x FOR KEY SHARE;
  END LOOP;

  IF v_id IS NULL THEN
    INSERT INTO grupos_precio (nombre, descripcion, sucursal_id)
    VALUES (v_nombre, v_desc, v_suc)
    RETURNING id INTO v_id;
    UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;
  ELSE
    PERFORM 1 FROM grupos_precio WHERE id = v_id AND sucursal_id = v_suc FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'La condición no existe en esta sucursal (puede que otro la haya eliminado).' USING ERRCODE = '22023';
    END IF;
    UPDATE grupos_precio SET nombre = v_nombre, descripcion = v_desc
     WHERE id = v_id AND sucursal_id = v_suc
       AND (nombre, descripcion) IS DISTINCT FROM (v_nombre::varchar, v_desc);
  END IF;

  -- Productos: conciliar por producto_id.
  DELETE FROM grupo_precio_productos
   WHERE grupo_precio_id = v_id AND sucursal_id = v_suc AND producto_id <> ALL (v_prods);
  INSERT INTO grupo_precio_productos (grupo_precio_id, producto_id, sucursal_id)
  SELECT v_id, x, v_suc FROM unnest(v_prods) x ORDER BY x
  ON CONFLICT (grupo_precio_id, producto_id) DO NOTHING;

  -- Escalas: conciliar por cantidad mínima (UNIQUE en la condición), conservando el id. Las bajas
  -- primero: liberan la cantidad. Borrar una escala se lleva sus mínimos (CASCADE).
  DELETE FROM grupo_precio_escalas
   WHERE grupo_precio_id = v_id AND sucursal_id = v_suc AND cantidad_minima <> ALL (v_cants);
  UPDATE grupo_precio_escalas e
     SET precio_unitario = n.precio, etiqueta = n.etiqueta, min_productos_distintos = n.k
    FROM jsonb_to_recordset(v_norm) AS n(cantidad integer, precio numeric, etiqueta text, k integer)
   WHERE e.grupo_precio_id = v_id AND e.sucursal_id = v_suc AND e.cantidad_minima = n.cantidad
     AND (e.precio_unitario, e.etiqueta::text, e.min_productos_distintos) IS DISTINCT FROM (n.precio, n.etiqueta, n.k);
  INSERT INTO grupo_precio_escalas (grupo_precio_id, cantidad_minima, precio_unitario, etiqueta,
                                    min_productos_distintos, sucursal_id)
  SELECT v_id, n.cantidad, n.precio, n.etiqueta, n.k, v_suc
    FROM jsonb_to_recordset(v_norm) AS n(cantidad integer, precio numeric, etiqueta text, k integer)
   WHERE NOT EXISTS (SELECT 1 FROM grupo_precio_escalas e
                      WHERE e.grupo_precio_id = v_id AND e.cantidad_minima = n.cantidad)
   ORDER BY n.cantidad;

  -- Mínimos por producto: se escriben los que valen y se borran los que sobran.
  DELETE FROM grupo_precio_escala_minimos m
   USING grupo_precio_escalas e
   WHERE m.escala_id = e.id AND e.grupo_precio_id = v_id AND e.sucursal_id = v_suc
     AND NOT EXISTS (
       SELECT 1 FROM jsonb_array_elements(v_norm) n, jsonb_array_elements(n->'minimos') d
        WHERE (n->>'cantidad')::integer = e.cantidad_minima AND (d->>'producto')::bigint = m.producto_id);
  INSERT INTO grupo_precio_escala_minimos (escala_id, producto_id, cantidad_minima_por_item,
                                           precio_unitario_override, sucursal_id)
  SELECT e.id, (d->>'producto')::bigint, (d->>'cantidad')::integer, (d->>'override')::numeric, v_suc
    FROM jsonb_array_elements(v_norm) n
   CROSS JOIN LATERAL jsonb_array_elements(n->'minimos') d
    JOIN grupo_precio_escalas e
      ON e.grupo_precio_id = v_id AND e.sucursal_id = v_suc AND e.cantidad_minima = (n->>'cantidad')::integer
   ORDER BY e.id, (d->>'producto')::bigint
  ON CONFLICT (escala_id, producto_id) DO UPDATE
     SET cantidad_minima_por_item = EXCLUDED.cantidad_minima_por_item,
         precio_unitario_override = EXCLUDED.precio_unitario_override
   WHERE (grupo_precio_escala_minimos.cantidad_minima_por_item, grupo_precio_escala_minimos.precio_unitario_override)
         IS DISTINCT FROM (EXCLUDED.cantidad_minima_por_item, EXCLUDED.precio_unitario_override);

  RETURN jsonb_build_object('id', v_id, 'replay', false);
END
$fn$;

COMMENT ON FUNCTION public.guardar_condicion_mayorista(jsonb) IS
  'C4b (ola 2 de #1603, 1561-b12): alta (con `clave`, idempotente) o edición (con `id`) de una condición mayorista entera —nombre, productos, escalas y mínimos por producto— en una transacción. Sólo admin, en la sucursal activa. Concilia: las escalas conservan su id por cantidad mínima. Devuelve {id, replay}.';

-- =========================================================================
-- 3 · El alta de una promo, en una transacción
-- =========================================================================
CREATE FUNCTION public.crear_promocion(p_promocion jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_suc       bigint := public.current_sucursal_id();
  v_clave     uuid;
  v_nombre    text;
  v_tipo      text;
  v_inicio    date;
  v_fin       date;
  v_limite    integer;
  v_prior     integer;
  v_mueve     boolean;
  v_modo      text;
  v_ajuste    boolean;
  v_regalo    bigint;
  v_cont      bigint;
  v_unid      integer;
  v_stock_b   integer;
  v_desc      text;
  v_prods     bigint[];
  v_reglas    jsonb;
  v_claves    text[];
  v_id        bigint;
  v_previa    public.altas_por_clave%ROWTYPE;
  v_contenido text;
  v_x         bigint;
  v_fila      public.promociones%ROWTYPE;
BEGIN
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin crea promociones.' USING ERRCODE = '42501';
  END IF;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_promocion) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos de la promoción.' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_clave   := NULLIF(p_promocion->>'clave', '')::uuid;
    v_nombre  := btrim(COALESCE(p_promocion->>'nombre', ''));
    v_tipo    := COALESCE(NULLIF(p_promocion->>'tipo', ''), 'bonificacion');
    v_inicio  := NULLIF(p_promocion->>'fecha_inicio', '')::date;
    v_fin     := NULLIF(p_promocion->>'fecha_fin', '')::date;
    v_limite  := NULLIF(p_promocion->>'limite_usos', '')::integer;
    v_prior   := COALESCE(NULLIF(p_promocion->>'prioridad', '')::integer, 0);
    v_mueve   := COALESCE((p_promocion->>'regalo_mueve_stock')::boolean, false);
    v_modo    := COALESCE(NULLIF(p_promocion->>'modo_exclusion', ''), 'acumulable');
    v_ajuste  := COALESCE((p_promocion->>'ajuste_automatico')::boolean, false);
    v_regalo  := NULLIF(p_promocion->>'producto_regalo_id', '')::bigint;
    v_cont    := NULLIF(p_promocion->>'ajuste_producto_id', '')::bigint;
    v_unid    := NULLIF(p_promocion->>'unidades_por_bloque', '')::integer;
    v_stock_b := NULLIF(p_promocion->>'stock_por_bloque', '')::integer;
    v_desc    := NULLIF(btrim(COALESCE(p_promocion->>'descripcion_regalo', '')), '');
    IF jsonb_typeof(p_promocion->'producto_ids') IS DISTINCT FROM 'array'
       OR jsonb_typeof(p_promocion->'reglas') IS DISTINCT FROM 'array' THEN
      RAISE EXCEPTION USING ERRCODE = '22P02';
    END IF;
    SELECT COALESCE(array_agg(DISTINCT (e #>> '{}')::bigint), '{}') INTO v_prods
      FROM jsonb_array_elements(p_promocion->'producto_ids') e;
    v_reglas := p_promocion->'reglas';
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato de la promoción con un formato inválido.' USING ERRCODE = '22023';
  END;

  -- Lo que pide el formulario (ModalPromocion) y las restricciones de las tablas, con su motivo.
  IF v_nombre = '' THEN
    RAISE EXCEPTION 'La promoción necesita un nombre.' USING ERRCODE = '22023';
  END IF;
  IF v_inicio IS NULL THEN
    RAISE EXCEPTION 'La promoción necesita una fecha de inicio.' USING ERRCODE = '22023';
  END IF;
  IF v_fin IS NOT NULL AND v_fin < v_inicio THEN
    RAISE EXCEPTION 'La fecha de fin no puede ser anterior a la de inicio.' USING ERRCODE = '22023';
  END IF;
  IF v_tipo <> 'bonificacion' THEN
    RAISE EXCEPTION 'El tipo de la promoción no es válido.' USING ERRCODE = '22023';
  END IF;
  IF v_modo NOT IN ('acumulable', 'excluyente') THEN
    RAISE EXCEPTION 'El modo de la promoción no es válido.' USING ERRCODE = '22023';
  END IF;
  IF v_limite IS NOT NULL AND v_limite <= 0 THEN
    RAISE EXCEPTION 'El límite de usos es un número entero mayor a 0 (vacío es sin límite).' USING ERRCODE = '22023';
  END IF;
  IF (v_unid IS NOT NULL AND v_unid <= 0) OR (v_stock_b IS NOT NULL AND v_stock_b <= 0) THEN
    RAISE EXCEPTION 'Las unidades por bloque tienen que ser mayores a 0.' USING ERRCODE = '22023';
  END IF;
  IF cardinality(v_prods) = 0 THEN
    RAISE EXCEPTION 'Elegí al menos un producto para la promoción.' USING ERRCODE = '22023';
  END IF;
  IF (SELECT count(*) FROM productos WHERE sucursal_id = v_suc AND id = ANY (v_prods)) <> cardinality(v_prods) THEN
    RAISE EXCEPTION 'Algún producto de la promoción no existe en esta sucursal.' USING ERRCODE = '22023';
  END IF;
  IF v_regalo IS NOT NULL AND NOT EXISTS (SELECT 1 FROM productos WHERE id = v_regalo AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'El producto de regalo no existe en esta sucursal.' USING ERRCODE = '22023';
  END IF;
  IF v_cont IS NOT NULL AND NOT EXISTS (SELECT 1 FROM productos WHERE id = v_cont AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'El producto contenedor no existe en esta sucursal.' USING ERRCODE = '22023';
  END IF;
  IF v_ajuste THEN
    -- Fracción: se regala una parte del contenedor y la barra descuenta el contenedor por bloques.
    IF v_desc IS NULL THEN
      RAISE EXCEPTION 'Escribí una descripción del regalo (ej: "1 botella Manaos Naranja 600cc").' USING ERRCODE = '22023';
    END IF;
    IF v_cont IS NULL THEN
      RAISE EXCEPTION 'Elegí el producto del que se descuenta el stock (el contenedor).' USING ERRCODE = '22023';
    END IF;
    IF v_unid IS NULL THEN
      RAISE EXCEPTION 'Ingresá cuántas subunidades forman una unidad del producto contenedor.' USING ERRCODE = '22023';
    END IF;
  ELSIF v_regalo IS NULL THEN
    RAISE EXCEPTION 'Elegí el producto de regalo.' USING ERRCODE = '22023';
  END IF;

  IF EXISTS (SELECT 1 FROM jsonb_array_elements(v_reglas) r
              WHERE jsonb_typeof(r) IS DISTINCT FROM 'object'
                 OR COALESCE(btrim(r->>'clave'), '') = ''
                 OR jsonb_typeof(r->'valor') IS DISTINCT FROM 'number'
                 OR CASE WHEN (r->>'valor') ~ '^[0-9]{1,10}$'
                         THEN (r->>'valor')::bigint NOT BETWEEN 1 AND 2147483647
                         ELSE true END) THEN
    RAISE EXCEPTION 'Las cantidades de la promoción tienen que ser números enteros mayores a 0.' USING ERRCODE = '22023';
  END IF;
  SELECT COALESCE(array_agg(btrim(r->>'clave')), '{}') INTO v_claves FROM jsonb_array_elements(v_reglas) r;
  IF cardinality(v_claves) <> (SELECT count(DISTINCT c) FROM unnest(v_claves) c) THEN
    RAISE EXCEPTION 'Una regla de la promoción está repetida.' USING ERRCODE = '22023';
  END IF;
  IF NOT (v_claves @> ARRAY['cantidad_compra', 'cantidad_bonificacion']) THEN
    RAISE EXCEPTION 'La promoción necesita la cantidad de compra y la de bonificación.' USING ERRCODE = '22023';
  END IF;

  -- La clave del formulario: el reintento de la misma alta devuelve la que ya se creó.
  IF v_clave IS NULL THEN
    RAISE EXCEPTION 'Falta la clave del alta: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  v_contenido := md5((p_promocion - 'clave')::text);
  INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
  VALUES (v_clave, 'promocion', auth.uid(), v_suc, v_contenido)
  ON CONFLICT (clave) DO NOTHING;
  IF NOT FOUND THEN
    SELECT * INTO v_previa FROM altas_por_clave WHERE clave = v_clave;
    IF v_previa.operacion <> 'promocion' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
       OR v_previa.sucursal_id <> v_suc THEN
      RAISE EXCEPTION 'Esta clave de alta ya se usó para otra operación: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
    END IF;
    IF v_previa.contenido <> v_contenido THEN
      RAISE EXCEPTION 'Esta promoción ya se creó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y corregila desde la lista.' USING ERRCODE = '22023';
    END IF;
    SELECT * INTO v_fila FROM promociones WHERE id = v_previa.entidad_id AND sucursal_id = v_suc;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Esta promoción ya se había creado con el intento anterior y después se eliminó: cerrá esta ventana y creala de nuevo.' USING ERRCODE = '22023';
    END IF;
    RETURN jsonb_build_object('id', v_fila.id, 'replay', true, 'promocion', to_jsonb(v_fila));
  END IF;

  -- Los productos que toman el KEY SHARE de las FK (regalo, contenedor y los de la promo), por id
  -- y antes de escribir: la venta los toma FOR UPDATE, también por id.
  FOR v_x IN SELECT p.id FROM productos p
              WHERE p.sucursal_id = v_suc
                AND (p.id = ANY (v_prods) OR p.id = v_regalo OR p.id = v_cont)
              ORDER BY p.id LOOP
    PERFORM 1 FROM productos WHERE id = v_x FOR KEY SHARE;
  END LOOP;

  INSERT INTO promociones (nombre, tipo, fecha_inicio, fecha_fin, limite_usos, producto_regalo_id, prioridad,
                           regalo_mueve_stock, modo_exclusion, ajuste_automatico, ajuste_producto_id,
                           unidades_por_bloque, stock_por_bloque, descripcion_regalo, sucursal_id)
  VALUES (v_nombre, v_tipo, v_inicio, v_fin, v_limite, v_regalo, v_prior,
          v_mueve, v_modo, v_ajuste, v_cont,
          v_unid, v_stock_b, v_desc, v_suc)
  RETURNING id INTO v_id;

  INSERT INTO promocion_productos (promocion_id, producto_id, sucursal_id)
  SELECT v_id, x, v_suc FROM unnest(v_prods) x ORDER BY x;

  INSERT INTO promocion_reglas (promocion_id, clave, valor, sucursal_id)
  SELECT v_id, btrim(r->>'clave'), (r->>'valor')::numeric, v_suc
    FROM jsonb_array_elements(v_reglas) r;

  UPDATE altas_por_clave SET entidad_id = v_id WHERE clave = v_clave;

  SELECT * INTO v_fila FROM promociones WHERE id = v_id;
  RETURN jsonb_build_object('id', v_id, 'replay', false, 'promocion', to_jsonb(v_fila));
END
$fn$;

COMMENT ON FUNCTION public.crear_promocion(jsonb) IS
  'C4b (ola 2 de #1603, 1561-b12): el alta de una promo con sus productos y sus reglas en una transacción, con `clave` (idempotente). Sólo admin, en la sucursal activa. La edición es cambiar_regalo_promocion. Devuelve {id, replay, promocion}.';

-- =========================================================================
-- 4 · Los roles extra de un usuario, en una transacción
-- =========================================================================
CREATE FUNCTION public.guardar_roles_extra(p_usuario_id uuid, p_roles text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_suc   bigint := public.current_sucursal_id();
  v_roles text[];
  v_malo  text;
BEGIN
  -- Lo de la policy perfil_roles_write_admin: admin activo, en la sucursal activa, que abarca
  -- todas las sucursales del usuario, y el usuario es de esa sucursal.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin cambia los roles extra de un usuario.' USING ERRCODE = '42501';
  END IF;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  IF p_usuario_id IS NULL THEN
    RAISE EXCEPTION 'Falta el usuario.' USING ERRCODE = '22023';
  END IF;
  IF NOT public.admin_abarca_sucursales_de(p_usuario_id) THEN
    RAISE EXCEPTION 'No podés editar a este usuario: también trabaja en sucursales que no son tuyas. Lo edita un admin de todas ellas.' USING ERRCODE = '42501';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                  WHERE us.usuario_id = p_usuario_id AND us.sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'El usuario no trabaja en esta sucursal.' USING ERRCODE = '22023';
  END IF;

  v_roles := ARRAY(SELECT DISTINCT btrim(r) FROM unnest(COALESCE(p_roles, '{}')) r ORDER BY 1);
  SELECT r INTO v_malo FROM unnest(v_roles) r WHERE r IS NULL OR r NOT IN ('transportista') LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'Rol extra desconocido: %. El único rol extra es «transportista» (puede llevar la ruta).',
      COALESCE(v_malo, '(vacío)') USING ERRCODE = '22023';
  END IF;

  DELETE FROM perfil_roles
   WHERE usuario_id = p_usuario_id AND sucursal_id = v_suc AND rol <> ALL (v_roles);
  INSERT INTO perfil_roles (usuario_id, sucursal_id, rol, created_by)
  SELECT p_usuario_id, v_suc, r, auth.uid() FROM unnest(v_roles) r ORDER BY r
  ON CONFLICT (usuario_id, sucursal_id, rol) DO NOTHING;

  RETURN jsonb_build_object('roles', to_jsonb(v_roles));
END
$fn$;

COMMENT ON FUNCTION public.guardar_roles_extra(uuid, text[]) IS
  'C4b (ola 2 de #1603, 1561-b12): deja los roles extra (perfil_roles) del usuario en la sucursal activa como la lista pedida, en una transacción. Lo mismo que la policy perfil_roles_write_admin: admin activo que abarca las sucursales del usuario, y el usuario es de la sucursal activa. Repetirla no cambia nada.';

-- =========================================================================
-- 5 · Los descuentos por categoría de un cliente, en una transacción
-- =========================================================================
CREATE FUNCTION public.guardar_descuentos_categoria(p_cliente_id bigint, p_descuentos jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_deseados jsonb := '[]'::jsonb;
  v_r        record;
  v_cat      text;
  v_pct      numeric;
BEGIN
  -- Lo de las policies cdc_insert y cdc_delete: admin activo y cliente de la sucursal activa.
  IF NOT public.es_admin() THEN
    RAISE EXCEPTION 'Sólo un admin cambia los descuentos por categoría de un cliente.' USING ERRCODE = '42501';
  END IF;
  IF p_cliente_id IS NULL OR NOT public.cliente_de_sucursal_activa(p_cliente_id) THEN
    RAISE EXCEPTION 'El cliente no es de esta sucursal.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(COALESCE(p_descuentos, '[]'::jsonb)) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Los descuentos por categoría no tienen la forma esperada.' USING ERRCODE = '22023';
  END IF;

  -- Una fila por categoría, sin mirar mayúsculas ni los espacios de los bordes: la última gana.
  -- Una sin categoría no cuenta (como replaceCategoriaDiscounts).
  FOR v_r IN SELECT d, o FROM jsonb_array_elements(COALESCE(p_descuentos, '[]'::jsonb)) WITH ORDINALITY AS t(d, o) ORDER BY o LOOP
    IF jsonb_typeof(v_r.d) IS DISTINCT FROM 'object'
       OR jsonb_typeof(COALESCE(v_r.d->'categoria', 'null'::jsonb)) NOT IN ('string', 'null') THEN
      RAISE EXCEPTION 'Los descuentos por categoría no tienen la forma esperada.' USING ERRCODE = '22023';
    END IF;
    v_cat := btrim(COALESCE(v_r.d->>'categoria', ''));
    CONTINUE WHEN v_cat = '';
    IF jsonb_typeof(v_r.d->'descuento_porcentaje') IS DISTINCT FROM 'number' THEN
      RAISE EXCEPTION 'El descuento de «%» tiene que ser un número de 0 a 100.', v_cat USING ERRCODE = '22023';
    END IF;
    v_pct := round((v_r.d->>'descuento_porcentaje')::numeric, 2);
    IF NOT (v_pct >= 0 AND v_pct <= 100) THEN
      RAISE EXCEPTION 'El descuento de «%» tiene que ser un número de 0 a 100.', v_cat USING ERRCODE = '22023';
    END IF;
    v_deseados := (SELECT COALESCE(jsonb_agg(x), '[]'::jsonb) FROM jsonb_array_elements(v_deseados) x
                    WHERE upper(x->>'categoria') <> upper(v_cat))
                  || jsonb_build_object('categoria', v_cat, 'pct', v_pct);
  END LOOP;

  -- El cliente, tomado: dos guardados a la vez del mismo cliente van de a uno.
  PERFORM 1 FROM clientes WHERE id = p_cliente_id FOR NO KEY UPDATE;

  -- Lo que no está como se pidió (categoría escrita igual y mismo valor) se borra; lo que falta se
  -- inserta. Así no queda nunca sin los descuentos que no cambiaron.
  DELETE FROM cliente_descuentos_categoria c
   WHERE c.cliente_id = p_cliente_id
     AND NOT EXISTS (SELECT 1 FROM jsonb_array_elements(v_deseados) d
                      WHERE d->>'categoria' = c.categoria AND (d->>'pct')::numeric = c.descuento_porcentaje);
  INSERT INTO cliente_descuentos_categoria (cliente_id, categoria, descuento_porcentaje)
  SELECT p_cliente_id, d->>'categoria', (d->>'pct')::numeric
    FROM jsonb_array_elements(v_deseados) d
   ORDER BY d->>'categoria'
  ON CONFLICT (cliente_id, categoria) DO NOTHING;

  RETURN jsonb_build_object('descuentos', (
    SELECT COALESCE(jsonb_agg(jsonb_build_object('categoria', c.categoria,
                                                 'descuento_porcentaje', c.descuento_porcentaje)
                              ORDER BY c.categoria), '[]'::jsonb)
      FROM cliente_descuentos_categoria c WHERE c.cliente_id = p_cliente_id));
END
$fn$;

COMMENT ON FUNCTION public.guardar_descuentos_categoria(bigint, jsonb) IS
  'C4b (ola 2 de #1603, 1598-b5): deja los descuentos por categoría del cliente como la lista pedida, en una transacción (antes eran un INSERT, un DELETE y otro INSERT REST con restitución si fallaba). Lo mismo que las policies cdc_insert / cdc_delete: admin activo y cliente de la sucursal activa. Repetirla no cambia nada.';

-- Las cuatro nuevas: EXECUTE sólo para authenticated (las llama el front) y service_role.
REVOKE ALL ON FUNCTION public.guardar_condicion_mayorista(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.crear_promocion(jsonb) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.guardar_roles_extra(uuid, text[]) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.guardar_descuentos_categoria(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_condicion_mayorista(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.crear_promocion(jsonb) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_roles_extra(uuid, text[]) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.guardar_descuentos_categoria(bigint, jsonb) TO authenticated, service_role;

-- =========================================================================
-- 5b · v2 · La versión de un cliente
-- =========================================================================
-- La edición de un cliente compara la versión que abrió (`updated_at_esperado`), como la de un
-- gasto, un combo o una promo. `clientes` no tenía versión: se suma la columna y un trigger que la
-- mueve cuando cambia algo que no sea `saldo_cuenta` (lo escriben los pedidos y los pagos en cada
-- venta: con eso, cualquier venta en el medio parecería «otro lo cambió»). Un UPDATE que no cambia
-- nada tampoco la mueve. El trigger va último (`zz`): `clientes_proteger_columnas_preventista`
-- compara OLD y NEW columna por columna y no tiene que ver esta.
ALTER TABLE public.clientes ADD COLUMN updated_at timestamptz NOT NULL DEFAULT now();

COMMENT ON COLUMN public.clientes.updated_at IS
  'C4b (ola 2 de #1603): la versión del cliente. La pone trg_clientes_zz_version en cada cambio que no sea saldo_cuenta; la compara guardar_cliente (updated_at_esperado). Lo que mande el cliente no cuenta.';

CREATE FUNCTION public.clientes_version()
RETURNS trigger
LANGUAGE plpgsql
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF (to_jsonb(NEW) - 'saldo_cuenta' - 'updated_at') = (to_jsonb(OLD) - 'saldo_cuenta' - 'updated_at') THEN
    NEW.updated_at := OLD.updated_at;
  ELSE
    NEW.updated_at := now();
  END IF;
  RETURN NEW;
END
$fn$;

REVOKE ALL ON FUNCTION public.clientes_version() FROM PUBLIC, anon, authenticated;

CREATE TRIGGER trg_clientes_zz_version
  BEFORE UPDATE ON public.clientes
  FOR EACH ROW EXECUTE FUNCTION public.clientes_version();

-- =========================================================================
-- 5c · v2 · La clave del alta de un cliente
-- =========================================================================
-- guardar_cliente corre como quien llama (ver 5d) y `altas_por_clave` es sólo de server: estas
-- dos la leen y la escriben por él, sólo para el que llama, en la sucursal activa y para la
-- operación 'cliente'. La primera reserva la clave (o devuelve el cliente que ya entró con ella);
-- la segunda le anota el cliente. Si el alta falla, la transacción entera (la reserva incluida) se
-- deshace.
CREATE FUNCTION public._alta_cliente_tomar_clave(p_clave uuid, p_contenido text)
RETURNS bigint
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  v_suc    bigint := public.current_sucursal_id();
  v_previa public.altas_por_clave%ROWTYPE;
BEGIN
  -- Quien puede dar de alta un cliente (mt_clientes_insert): es_preventista() (admin y encargado
  -- incluidos), en la sucursal activa.
  IF auth.uid() IS NULL OR NOT public.es_preventista() THEN
    RAISE EXCEPTION 'No podés dar de alta clientes.' USING ERRCODE = '42501';
  END IF;
  IF v_suc IS NULL OR p_clave IS NULL OR p_contenido IS NULL THEN
    RAISE EXCEPTION 'Falta la clave del alta o la sucursal activa: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  INSERT INTO altas_por_clave (clave, operacion, usuario_id, sucursal_id, contenido)
  VALUES (p_clave, 'cliente', auth.uid(), v_suc, p_contenido)
  ON CONFLICT (clave) DO NOTHING;
  IF FOUND THEN
    RETURN NULL;
  END IF;
  SELECT * INTO v_previa FROM altas_por_clave WHERE clave = p_clave;
  IF v_previa.operacion <> 'cliente' OR v_previa.usuario_id IS DISTINCT FROM auth.uid()
     OR v_previa.sucursal_id <> v_suc THEN
    RAISE EXCEPTION 'Esta clave de alta ya se usó para otra operación: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  IF v_previa.contenido <> p_contenido THEN
    RAISE EXCEPTION 'Este cliente ya se creó con el intento anterior y lo que mandaste ahora es distinto: cerrá esta ventana y corregilo desde la lista.' USING ERRCODE = '22023';
  END IF;
  IF v_previa.entidad_id IS NULL
     OR NOT EXISTS (SELECT 1 FROM clientes WHERE id = v_previa.entidad_id AND sucursal_id = v_suc) THEN
    RAISE EXCEPTION 'Este cliente ya se había creado con el intento anterior y después se eliminó: cerrá esta ventana y crealo de nuevo.' USING ERRCODE = '22023';
  END IF;
  RETURN v_previa.entidad_id;
END
$fn$;

CREATE FUNCTION public._alta_cliente_cerrar_clave(p_clave uuid, p_cliente_id bigint)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $fn$
BEGIN
  IF auth.uid() IS NULL OR NOT public.es_preventista() THEN
    RAISE EXCEPTION 'No podés dar de alta clientes.' USING ERRCODE = '42501';
  END IF;
  -- Sólo la reserva propia y sin cliente, de la sucursal activa, y un cliente de esa sucursal.
  UPDATE altas_por_clave a
     SET entidad_id = p_cliente_id
   WHERE a.clave = p_clave AND a.operacion = 'cliente' AND a.usuario_id = auth.uid()
     AND a.sucursal_id = public.current_sucursal_id() AND a.entidad_id IS NULL
     AND EXISTS (SELECT 1 FROM clientes c WHERE c.id = p_cliente_id AND c.sucursal_id = a.sucursal_id);
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No se pudo anotar la clave del alta del cliente.' USING ERRCODE = '22023';
  END IF;
END
$fn$;

REVOKE ALL ON FUNCTION public._alta_cliente_tomar_clave(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public._alta_cliente_cerrar_clave(uuid, bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public._alta_cliente_tomar_clave(uuid, text) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public._alta_cliente_cerrar_clave(uuid, bigint) TO authenticated, service_role;

-- =========================================================================
-- 5d · v2 · El alta y la edición de un cliente, en una transacción
-- =========================================================================
-- Antes: el INSERT o el PATCH de `clientes`, después `cliente_preventistas` (un DELETE y un INSERT
-- por preventista) y después los descuentos por categoría, en llamadas REST separadas. Ahora es
-- una llamada. Corre como QUIEN LLAMA (SECURITY INVOKER) a propósito: así rigen exactamente las
-- mismas policies (mt_clientes_insert / mt_clientes_update / cp_insert / cp_delete, la
-- visibilidad de `_cliente_visible`) y los mismos triggers que con el REST, que se eximen cuando
-- `current_user` no es 'authenticated' (reservado, vale blanco, comodín, crédito y descuento sólo
-- de admin, alta en zona propia, columnas protegidas del preventista, el tipo de documento del
-- valor, la reasignación por zona). Una definer los salteaba todos. Los descuentos van por
-- guardar_descuentos_categoria (sólo admin), en la misma transacción.
--   · Escribe sólo las columnas que vienen en `campos` (como el PATCH: los triggers `UPDATE OF`
--     ven la misma lista). El tipo de documento lo recalcula del valor su trigger (B17).
--   · No reasigna nada por su cuenta: la zona la sigue mandando el trigger, y la lista de
--     preventistas es la que eligió quien guarda (la diferencia contra `preventista_ids_previos`,
--     o contra lo que hay), como hacía el front.
--   · El alta lleva la clave del formulario: el reintento devuelve el cliente que ya entró.
--   · El duplicado: lo que bloquea `verificar_duplicado_cliente` no entra, y lo que avisa entra
--     sólo con `duplicado_confirmado` (el formulario ya lo preguntó; esto ataja la carrera).
--   · La edición compara `updated_at_esperado` con la fila tomada: si otro la guardó, devuelve
--     `codigo` 'cliente_cambiado' sin escribir nada.
-- Mientras corra como quien llama, necesita los grants REST de clientes y cliente_preventistas:
-- revocarlos obliga a pasarla a definer replicando esas guardas.
CREATE FUNCTION public.guardar_cliente(p_cliente jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  c_campos constant text[] := ARRAY[
    'razon_social', 'nombre_fantasia', 'direccion', 'aclaracion_direccion', 'telefono', 'cuit',
    'tipo_documento', 'zona_id', 'latitud', 'longitud', 'limite_credito', 'dias_credito', 'descuento_porcentaje',
    'contacto', 'horarios_atencion', 'dias_atencion', 'horarios_atencion_original', 'horario_entrega',
    'sin_horario_fijo', 'activo', 'rubro', 'notas', 'reservado_admin', 'tipo_factura_default',
    'place_id', 'es_comodin'];
  v_suc        bigint := public.current_sucursal_id();
  v_id         bigint;
  v_clave      uuid;
  v_esperado   timestamptz;
  v_campos     jsonb;
  v_keys       text[];
  v_malo       text;
  v_confirmado boolean;
  v_deseados   uuid[];
  v_previos    uuid[];
  v_viejo      public.clientes%ROWTYPE;
  v_nuevo      public.clientes%ROWTYPE;
  v_previa     bigint;
  v_ver        jsonb;
  v_sql        text;
  v_x          uuid;
  v_toca_dir   boolean;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sin sesión: volvé a entrar.' USING ERRCODE = '42501';
  END IF;
  IF v_suc IS NULL THEN
    RAISE EXCEPTION 'No hay una sucursal activa: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_typeof(p_cliente) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_cliente->'campos', '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos del cliente.' USING ERRCODE = '22023';
  END IF;

  BEGIN
    v_id         := NULLIF(p_cliente->>'id', '')::bigint;
    v_clave      := NULLIF(p_cliente->>'clave', '')::uuid;
    v_esperado   := NULLIF(p_cliente->>'updated_at_esperado', '')::timestamptz;
    v_confirmado := COALESCE((p_cliente->>'duplicado_confirmado')::boolean, false);
    IF p_cliente ? 'preventista_ids' THEN
      IF jsonb_typeof(p_cliente->'preventista_ids') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22P02';
      END IF;
      SELECT COALESCE(array_agg(DISTINCT (e #>> '{}')::uuid), '{}') INTO v_deseados
        FROM jsonb_array_elements(p_cliente->'preventista_ids') e;
    END IF;
    IF jsonb_typeof(p_cliente->'preventista_ids_previos') = 'array' THEN
      SELECT COALESCE(array_agg(DISTINCT (e #>> '{}')::uuid), '{}') INTO v_previos
        FROM jsonb_array_elements(p_cliente->'preventista_ids_previos') e;
    END IF;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del cliente con un formato inválido.' USING ERRCODE = '22023';
  END;

  -- Sólo las columnas que el formulario escribe.
  v_campos := COALESCE(p_cliente->'campos', '{}'::jsonb);
  SELECT k INTO v_malo FROM jsonb_object_keys(v_campos) k WHERE k <> ALL (c_campos) ORDER BY k LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'El dato «%» del cliente no se guarda desde acá.', v_malo USING ERRCODE = '22023';
  END IF;
  v_keys := ARRAY(SELECT k FROM jsonb_object_keys(v_campos) k ORDER BY k);

  IF v_id IS NULL THEN
    -- ---------------------------------------------------------------- alta -
    IF v_clave IS NULL THEN
      RAISE EXCEPTION 'Falta la clave del alta: recargá la página e intentá de nuevo.' USING ERRCODE = '22023';
    END IF;
    v_previa := public._alta_cliente_tomar_clave(v_clave, md5((p_cliente - 'clave')::text));
    IF v_previa IS NOT NULL THEN
      SELECT * INTO v_nuevo FROM clientes WHERE id = v_previa;
      RETURN jsonb_build_object('success', true, 'replay', true, 'cliente', to_jsonb(v_nuevo),
        'preventista_ids', (SELECT COALESCE(jsonb_agg(cp.preventista_id ORDER BY cp.preventista_id), '[]'::jsonb)
                              FROM cliente_preventistas cp WHERE cp.cliente_id = v_previa));
    END IF;
    IF cardinality(v_keys) = 0 THEN
      RAISE EXCEPTION 'Faltan los datos del cliente.' USING ERRCODE = '22023';
    END IF;
    v_ver := public.verificar_duplicado_cliente(NULLIF(v_campos->>'latitud', '')::numeric,
                                                NULLIF(v_campos->>'longitud', '')::numeric,
                                                v_campos->>'direccion', NULL);
    IF COALESCE((v_ver->>'bloquea')::boolean, false) THEN
      RAISE EXCEPTION 'Ya hay un cliente en esa dirección o en ese mismo punto: no se creó nada.' USING ERRCODE = '23505';
    END IF;
    IF COALESCE((v_ver->>'avisa')::boolean, false) AND NOT v_confirmado THEN
      RAISE EXCEPTION 'Hay otro cliente muy cerca: no se creó nada. Volvé a guardar y confirmá que es otro comercio.' USING ERRCODE = '22023';
    END IF;
    v_sql := format('INSERT INTO public.clientes (%s, sucursal_id) SELECT %s, $2 FROM jsonb_populate_record(NULL::public.clientes, $1) r RETURNING *',
                    (SELECT string_agg(format('%I', k), ', ') FROM unnest(v_keys) k),
                    (SELECT string_agg(format('r.%I', k), ', ') FROM unnest(v_keys) k));
    EXECUTE v_sql INTO v_nuevo USING v_campos, v_suc;
    v_id := v_nuevo.id;
    PERFORM public._alta_cliente_cerrar_clave(v_clave, v_id);
  ELSE
    -- ------------------------------------------------------------ edición -
    -- Tomada con la RLS de quien guarda: si no la ve o no la puede editar, no hay fila.
    SELECT * INTO v_viejo FROM clientes WHERE id = v_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'El cliente no existe o no lo podés editar.' USING ERRCODE = '42501';
    END IF;
    IF v_esperado IS NOT NULL AND v_viejo.updated_at IS DISTINCT FROM v_esperado THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'cliente_cambiado', 'error',
        'Otro usuario cambió este cliente mientras lo editabas: no se guardó nada. Volvé a abrirlo para ver cómo quedó.');
    END IF;
    -- El duplicado se mira sólo si cambia lo que compara (como cambiaIdentidadDuplicado).
    v_toca_dir := (v_campos ? 'direccion' AND (v_campos->>'direccion') IS DISTINCT FROM v_viejo.direccion)
               OR (v_campos ? 'latitud' AND NULLIF(v_campos->>'latitud', '')::numeric IS DISTINCT FROM v_viejo.latitud)
               OR (v_campos ? 'longitud' AND NULLIF(v_campos->>'longitud', '')::numeric IS DISTINCT FROM v_viejo.longitud);
    IF v_toca_dir THEN
      v_ver := public.verificar_duplicado_cliente(
        CASE WHEN v_campos ? 'latitud' THEN NULLIF(v_campos->>'latitud', '')::numeric ELSE v_viejo.latitud END,
        CASE WHEN v_campos ? 'longitud' THEN NULLIF(v_campos->>'longitud', '')::numeric ELSE v_viejo.longitud END,
        CASE WHEN v_campos ? 'direccion' THEN v_campos->>'direccion' ELSE v_viejo.direccion END,
        v_id);
      IF COALESCE((v_ver->>'bloquea')::boolean, false) THEN
        RAISE EXCEPTION 'Ya hay otro cliente en esa dirección o en ese mismo punto: no se guardó nada.' USING ERRCODE = '23505';
      END IF;
      IF COALESCE((v_ver->>'avisa')::boolean, false) AND NOT v_confirmado THEN
        RAISE EXCEPTION 'Hay otro cliente muy cerca: no se guardó nada. Volvé a guardar y confirmá que es otro comercio.' USING ERRCODE = '22023';
      END IF;
    END IF;
    IF cardinality(v_keys) > 0 THEN
      v_sql := format('UPDATE public.clientes c SET %s FROM jsonb_populate_record(NULL::public.clientes, $1) r WHERE c.id = $2 RETURNING c.*',
                      (SELECT string_agg(format('%I = r.%I', k, k), ', ') FROM unnest(v_keys) k));
      EXECUTE v_sql INTO v_nuevo USING v_campos, v_id;
      IF v_nuevo.id IS NULL THEN
        RAISE EXCEPTION 'El cliente no existe o no lo podés editar.' USING ERRCODE = '42501';
      END IF;
    END IF;
  END IF;

  -- ------------------------------------------------------- preventistas -
  -- La lista que eligió quien guarda, contra la que tenía al abrir (o contra la de la base). Lo
  -- que el trigger de la zona ya puso y está en la lista, se queda.
  IF v_deseados IS NOT NULL THEN
    IF v_previos IS NULL THEN
      v_previos := ARRAY(SELECT cp.preventista_id FROM cliente_preventistas cp WHERE cp.cliente_id = v_id);
    END IF;
    DELETE FROM cliente_preventistas
     WHERE cliente_id = v_id AND preventista_id = ANY (v_previos) AND preventista_id <> ALL (v_deseados);
    FOR v_x IN SELECT x FROM unnest(v_deseados) x WHERE x <> ALL (v_previos) ORDER BY x LOOP
      INSERT INTO cliente_preventistas (cliente_id, preventista_id) VALUES (v_id, v_x)
      ON CONFLICT DO NOTHING;
    END LOOP;
  END IF;

  -- ---------------------------------------------------------- descuentos -
  IF p_cliente ? 'descuentos_categoria' THEN
    PERFORM public.guardar_descuentos_categoria(v_id, p_cliente->'descuentos_categoria');
  END IF;

  SELECT * INTO v_nuevo FROM clientes WHERE id = v_id;
  RETURN jsonb_build_object('success', true, 'replay', false, 'cliente', to_jsonb(v_nuevo),
    'preventista_ids', (SELECT COALESCE(jsonb_agg(cp.preventista_id ORDER BY cp.preventista_id), '[]'::jsonb)
                          FROM cliente_preventistas cp WHERE cp.cliente_id = v_id));
END
$fn$;

COMMENT ON FUNCTION public.guardar_cliente(jsonb) IS
  'C4b v2 (ola 2 de #1603): alta (con `clave`, idempotente) o edición (con `id` y `updated_at_esperado`) de un cliente con sus preventistas y sus descuentos por categoría, en una transacción. SECURITY INVOKER a propósito: rigen las mismas policies y triggers que con el REST. Devuelve {success, replay, cliente, preventista_ids} o {success:false, codigo:''cliente_cambiado''}.';

REVOKE ALL ON FUNCTION public.guardar_cliente(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_cliente(jsonb) TO authenticated, service_role;

-- =========================================================================
-- 5e · v2 · Guardar un usuario (el perfil y sus roles extra), en una transacción
-- =========================================================================
-- Antes: el PATCH de `perfiles` y, si salía bien, guardar_roles_extra en otra llamada (si la
-- segunda fallaba, el perfil quedaba guardado y los roles no). Ahora es una. Corre como QUIEN LLAMA
-- (SECURITY INVOKER): el UPDATE de perfiles pasa por perfiles_update_admin (admin que abarca las
-- sucursales del usuario), los grants por columna de perfiles y sus triggers
-- (prevenir_autoescalada_perfil: nadie edita su propio perfil; perfiles_guard_desactivacion: nunca
-- sin un admin activo; soltar la cartera y las zonas) exactamente como con el REST. No toca policies
-- ni grants de perfiles (son de la tarjeta C6): si un día se revoca el UPDATE REST, esta pasa a
-- definer replicándolos. Los roles extra van por guardar_roles_extra en la misma transacción.
CREATE FUNCTION public.guardar_usuario(p_usuario jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path = public, pg_temp
AS $fn$
DECLARE
  c_campos constant text[] := ARRAY['nombre', 'rol', 'activo', 'zona'];
  v_id    uuid;
  v_campos jsonb;
  v_keys  text[];
  v_malo  text;
  v_roles text[];
  v_sql   text;
  v_rid   uuid;
  v_nom   text;
  v_rol   text;
  v_act   boolean;
  v_zona  text;
  v_hay   boolean := false;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'Sin sesión: volvé a entrar.' USING ERRCODE = '42501';
  END IF;
  IF jsonb_typeof(p_usuario) IS DISTINCT FROM 'object'
     OR jsonb_typeof(COALESCE(p_usuario->'campos', '{}'::jsonb)) IS DISTINCT FROM 'object' THEN
    RAISE EXCEPTION 'Faltan los datos del usuario.' USING ERRCODE = '22023';
  END IF;
  BEGIN
    v_id := (p_usuario->>'id')::uuid;
    IF p_usuario ? 'roles_extra' THEN
      IF jsonb_typeof(p_usuario->'roles_extra') IS DISTINCT FROM 'array' THEN
        RAISE EXCEPTION USING ERRCODE = '22P02';
      END IF;
      v_roles := ARRAY(SELECT e #>> '{}' FROM jsonb_array_elements(p_usuario->'roles_extra') e);
    END IF;
  EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'Hay un dato del usuario con un formato inválido.' USING ERRCODE = '22023';
  END;
  IF v_id IS NULL THEN
    RAISE EXCEPTION 'Falta el usuario.' USING ERRCODE = '22023';
  END IF;
  v_campos := COALESCE(p_usuario->'campos', '{}'::jsonb);
  SELECT k INTO v_malo FROM jsonb_object_keys(v_campos) k WHERE k <> ALL (c_campos) ORDER BY k LIMIT 1;
  IF FOUND THEN
    RAISE EXCEPTION 'El dato «%» del usuario no se guarda desde acá.', v_malo USING ERRCODE = '22023';
  END IF;
  v_keys := ARRAY(SELECT k FROM jsonb_object_keys(v_campos) k ORDER BY k);

  IF cardinality(v_keys) > 0 THEN
    -- Devuelve sólo lo que se escribe: el email de los demás no se lee desde acá.
    v_sql := format('UPDATE public.perfiles p SET %s FROM jsonb_populate_record(NULL::public.perfiles, $1) r WHERE p.id = $2 RETURNING p.id, p.nombre, p.rol, p.activo, p.zona',
                    (SELECT string_agg(format('%I = r.%I', k, k), ', ') FROM unnest(v_keys) k));
    EXECUTE v_sql INTO v_rid, v_nom, v_rol, v_act, v_zona USING v_campos, v_id;
    IF v_rid IS NULL THEN
      RAISE EXCEPTION 'No podés editar a este usuario: también trabaja en sucursales que no son tuyas. Lo edita un admin de todas ellas.' USING ERRCODE = '42501';
    END IF;
    v_hay := true;
  END IF;

  IF v_roles IS NOT NULL THEN
    PERFORM public.guardar_roles_extra(v_id, v_roles);
  END IF;

  RETURN jsonb_build_object('success', true,
    'perfil', CASE WHEN NOT v_hay THEN NULL
                   ELSE jsonb_build_object('id', v_rid, 'nombre', v_nom, 'rol', v_rol,
                                           'activo', v_act, 'zona', v_zona) END,
    'roles_extra', CASE WHEN v_roles IS NULL THEN NULL ELSE to_jsonb(v_roles) END);
END
$fn$;

COMMENT ON FUNCTION public.guardar_usuario(jsonb) IS
  'C4b v2 (ola 2 de #1603): guarda el perfil de un usuario (nombre, rol, activo, zona) y sus roles extra de la sucursal activa en una transacción. SECURITY INVOKER: rigen perfiles_update_admin, los grants por columna y los triggers de perfiles, como con el REST. Los roles van por guardar_roles_extra.';

REVOKE ALL ON FUNCTION public.guardar_usuario(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.guardar_usuario(jsonb) TO authenticated, service_role;

-- =========================================================================
-- 6 · guardar_combo: «otro lo cambió» y el orden del grupo
-- =========================================================================
DO $combo$
DECLARE
  v_def text := pg_get_functiondef('public.guardar_combo(jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_abajo    bigint;
BEGIN$a$,
$n$  v_abajo    bigint;
  -- C4b (1599-b8): la versión que vio quien edita y las de los combos del orden.
  v_esperado timestamptz;
  v_versiones jsonb;
  v_actual   timestamptz;
  v_x        bigint;
  v_vistos   bigint[];
  v_otro     text;
BEGIN$n$, 'guardar_combo · declaraciones');

  v_def := pg_temp.parche(v_def,
$a$    v_mover   := NULLIF(p_combo->>'producto_a_mover_id', '')::bigint;
$a$,
$n$    v_mover   := NULLIF(p_combo->>'producto_a_mover_id', '')::bigint;
    -- C4b (1599-b8): el updated_at del combo al abrirlo, y el de cada combo del orden.
    v_esperado := NULLIF(p_combo->>'updated_at_esperado', '')::timestamptz;
    IF jsonb_typeof(p_combo->'versiones') = 'object' THEN
      v_versiones := p_combo->'versiones';
      PERFORM NULLIF(value, '')::timestamptz FROM jsonb_each_text(v_versiones);
    ELSIF COALESCE(jsonb_typeof(p_combo->'versiones'), 'null') <> 'null' THEN
      RAISE EXCEPTION USING ERRCODE = '22P02';
    END IF;
    -- v2: los combos que tenía la lista de quien edita (todos los de la sucursal que vio).
    IF jsonb_typeof(p_combo->'vistos') = 'array' THEN
      SELECT COALESCE(array_agg((e #>> '{}')::bigint), '{}') INTO v_vistos
        FROM jsonb_array_elements(p_combo->'vistos') e;
    ELSIF COALESCE(jsonb_typeof(p_combo->'vistos'), 'null') <> 'null' THEN
      RAISE EXCEPTION USING ERRCODE = '22P02';
    END IF;
$n$, 'guardar_combo · lectura de la versión');

  v_def := pg_temp.parche(v_def,
$a$  IF v_id IS NULL THEN
    INSERT INTO combos (sucursal_id,$a$,
$n$  -- C4b (1599-b8, decisión del dueño D47 para la edición de un gasto, mismo molde): si otro
  -- guardó este combo, o cambió uno de los del orden que se reescribe, no se pisa. El combo y los
  -- del orden, tomados por id antes de comparar (dos guardados a la vez van de a uno). Sin las
  -- claves (un PWA de antes) no compara.
  -- v2: los guardados de combos de una sucursal van de a uno (son de admin y raros): así el que
  -- llega segundo ve el combo que el primero acaba de crear.
  PERFORM pg_advisory_xact_lock(hashtext('guardar_combo'), v_sucursal::integer);
  FOR v_x IN SELECT co.id FROM combos co
              WHERE co.sucursal_id = v_sucursal
                AND (co.id = v_id OR co.id = ANY (COALESCE(v_orden, '{}')))
              ORDER BY co.id LOOP
    PERFORM 1 FROM combos WHERE id = v_x FOR UPDATE;
  END LOOP;
  IF v_id IS NOT NULL AND v_esperado IS NOT NULL THEN
    SELECT co.updated_at INTO v_actual FROM combos co WHERE co.id = v_id AND co.sucursal_id = v_sucursal;
    IF FOUND AND v_actual IS DISTINCT FROM v_esperado THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'combo_cambiado', 'error',
        'Otro usuario cambió este combo mientras lo editabas: no se guardó nada. Volvé a abrirlo para ver cómo quedó.');
    END IF;
  END IF;
  IF v_versiones IS NOT NULL AND v_orden IS NOT NULL THEN
    IF EXISTS (SELECT 1 FROM unnest(v_orden) x
                 JOIN combos co ON co.id = x AND co.sucursal_id = v_sucursal
                WHERE x <> 0 AND x IS DISTINCT FROM v_id
                  AND co.updated_at IS DISTINCT FROM NULLIF(v_versiones->>(x::text), '')::timestamptz) THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'orden_cambiado', 'error',
        'Otro usuario cambió un combo que compite con éste mientras lo editabas: no se guardó nada. Revisá el orden con los combos de ahora y volvé a guardar.');
    END IF;
  END IF;
  -- v2: un combo activo que compite con éste (vende alguno de sus productos) y que quien edita no
  -- tenía en su lista: lo creó otro mientras tanto, y el orden que se guarda no lo cuenta.
  IF v_vistos IS NOT NULL THEN
    SELECT co.nombre INTO v_otro
      FROM combos co
     WHERE co.sucursal_id = v_sucursal AND co.activo
       AND co.id IS DISTINCT FROM v_id AND co.id <> ALL (v_vistos)
       AND EXISTS (
         SELECT 1 FROM combo_componentes cc
          WHERE cc.combo_id = co.id AND cc.sucursal_id = v_sucursal
            AND (cc.producto_id = ANY (v_resueltos)
                 OR EXISTS (SELECT 1 FROM productos pr
                             WHERE pr.sucursal_id = v_sucursal AND pr.activo AND pr.id = ANY (v_resueltos)
                               AND (pr.categoria_id = cc.categoria_id OR pr.subcategoria_id = cc.categoria_id))))
     ORDER BY co.id LIMIT 1;
    IF FOUND THEN
      RETURN jsonb_build_object('success', false, 'codigo', 'orden_cambiado', 'error',
        format('Otro usuario creó el combo «%s», que compite con éste, mientras lo editabas: no se guardó nada.', v_otro));
    END IF;
  END IF;

  IF v_id IS NULL THEN
    INSERT INTO combos (sucursal_id,$n$, 'guardar_combo · la comparación');

  v_def := pg_temp.parche(v_def,
$a$       SET prioridad = cardinality(v_orden) - e.o::integer + 1
      FROM unnest(v_orden) WITH ORDINALITY AS e(x, o)
     WHERE co.id = e.x AND co.sucursal_id = v_sucursal AND e.x <> 0 AND e.x <> v_id;$a$,
$n$       SET prioridad = cardinality(v_orden) - e.o::integer + 1,
           -- C4b: cambiarle la prioridad es cambiarlo; quien lo tenga abierto lo ve.
           updated_at = now()
      FROM unnest(v_orden) WITH ORDINALITY AS e(x, o)
     WHERE co.id = e.x AND co.sucursal_id = v_sucursal AND e.x <> 0 AND e.x <> v_id
       AND co.prioridad IS DISTINCT FROM cardinality(v_orden) - e.o::integer + 1;$n$, 'guardar_combo · el orden mueve la versión');

  -- La temporal de lo que vende cada lugar (hallazgo de B15): con `IF NOT EXISTS` la función
  -- reusaba una `_combo_resuelto` que quien llama hubiera creado en su sesión (con otras columnas
  -- o con un trigger suyo, que corría con los permisos del dueño de la función). Ahora la tira y la
  -- crea de nuevo, calificada; dos llamadas en la misma transacción siguen andando.
  v_def := pg_temp.parche(v_def,
$a$  CREATE TEMP TABLE IF NOT EXISTS _combo_resuelto (lugar integer, producto bigint) ON COMMIT DROP;
  TRUNCATE _combo_resuelto;
$a$,
$n$  -- C4b (hallazgo de B15): nunca la temporal de quien llama.
  DROP TABLE IF EXISTS pg_temp._combo_resuelto;
  CREATE TEMP TABLE pg_temp._combo_resuelto (lugar integer, producto bigint) ON COMMIT DROP;
$n$, 'guardar_combo · la temporal');
  -- El resto de las menciones, calificadas: son cuatro (el INSERT y tres lecturas).
  IF (SELECT count(*) FROM regexp_matches(v_def, '([^._])_combo_resuelto', 'g')) <> 4 THEN
    RAISE EXCEPTION 'mig NNN · guardar_combo: se esperaban 4 menciones sin calificar de _combo_resuelto';
  END IF;
  v_def := regexp_replace(v_def, '([^._])_combo_resuelto', '\1pg_temp._combo_resuelto', 'g');

  EXECUTE v_def;
END
$combo$;

-- =========================================================================
-- 7 · cambiar_regalo_promocion: «otro la cambió»
-- =========================================================================
DO $promo$
DECLARE
  v_def text := pg_get_functiondef('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_tomados      BOOLEAN := false;
BEGIN$a$,
$n$  v_tomados      BOOLEAN := false;
  -- C4b (1599-b8): el updated_at de la promo al abrirla.
  v_esperado     TIMESTAMPTZ;
BEGIN$n$, 'cambiar_regalo_promocion · declaraciones');

  v_def := pg_temp.parche(v_def,
$a$    IF p_datos ? 'fecha_inicio' AND NULLIF(p_datos->>'fecha_inicio', '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'La promoción necesita una fecha de inicio');
    END IF;
$a$,
$n$    IF p_datos ? 'fecha_inicio' AND NULLIF(p_datos->>'fecha_inicio', '') IS NULL THEN
      RETURN jsonb_build_object('success', false, 'error', 'La promoción necesita una fecha de inicio');
    END IF;
    IF p_datos ? 'updated_at_esperado' THEN
      BEGIN
        v_esperado := NULLIF(p_datos->>'updated_at_esperado', '')::timestamptz;
      EXCEPTION WHEN others THEN
        RETURN jsonb_build_object('success', false, 'error', 'La versión de la promoción no tiene la forma esperada');
      END;
    END IF;
$n$, 'cambiar_regalo_promocion · lectura de la versión');

  v_def := pg_temp.parche(v_def,
$a$  SELECT id, producto_regalo_id, ajuste_producto_id, ajuste_automatico INTO v_promo$a$,
$n$  SELECT id, producto_regalo_id, ajuste_producto_id, ajuste_automatico, updated_at INTO v_promo$n$,
    'cambiar_regalo_promocion · la promo con su versión');

  v_def := pg_temp.parche(v_def,
$a$  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;
$a$,
$n$  IF NOT FOUND THEN
    RETURN jsonb_build_object('success', false, 'error', 'Promoción no encontrada');
  END IF;
  -- C4b (1599-b8, el molde de la edición de un gasto): si otro la guardó mientras se editaba,
  -- no se pisa. Con la promo tomada. Sin la clave (un PWA de antes) no compara.
  IF v_esperado IS NOT NULL AND v_promo.updated_at IS DISTINCT FROM v_esperado THEN
    RETURN jsonb_build_object('success', false, 'codigo', 'promocion_cambiada', 'error',
      'Otro usuario cambió esta promoción mientras la editabas: no se guardó nada. Volvé a abrirla para ver cómo quedó.');
  END IF;
$n$, 'cambiar_regalo_promocion · la comparación');

  EXECUTE v_def;
END
$promo$;

-- PROMO-C (`auditoria_funciones_modo_regalo_vivo`): crear_promocion escribe la columna
-- regalo_mueve_stock de una promo nueva, sin pedidos. Se suma una línea a la lista, por ancla y
-- sin premisa de md5 (otras tarjetas le suman las suyas).
DO $promoc$
DECLARE
  v_def text := pg_get_functiondef('public.auditoria_funciones_modo_regalo_vivo()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$       'validar_cambio_unidades_por_bulto', 'cambiar_regalo_promocion',
$a$,
$n$       'validar_cambio_unidades_por_bulto', 'cambiar_regalo_promocion',
       -- C4b (ola 2 de #1603): el alta de una promo, que todavía no tiene pedidos.
       'crear_promocion',
$n$, 'auditoria_funciones_modo_regalo_vivo · crear_promocion');
  EXECUTE v_def;
END
$promoc$;

-- B15 (la 531): toda definer con pg_temp al final del search_path. Idempotente si la 531 ya entró.
ALTER FUNCTION public.guardar_combo(jsonb) SET search_path = public, pg_temp;
ALTER FUNCTION public.cambiar_regalo_promocion(bigint, bigint, bigint, boolean, jsonb) SET search_path = public, pg_temp;
ALTER FUNCTION public.auditoria_funciones_modo_regalo_vivo() SET search_path = public, pg_temp;

-- =========================================================================
-- 8 · La versión de la promo no la mueve la barra
-- =========================================================================
CREATE OR REPLACE FUNCTION public.update_promociones_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
 SET search_path TO 'public', 'pg_temp'
AS $function$
BEGIN
  -- C4b (ola 2 de #1603): updated_at es la versión de la promo que compara la edición
  -- (cambiar_regalo_promocion). La barra de regalos de fracción escribe usos_pendientes en cada
  -- venta: ese UPDATE, solo, no es cambiarla. Una UPDATE que no cambia nada tampoco.
  IF (to_jsonb(NEW) - 'usos_pendientes' - 'updated_at') = (to_jsonb(OLD) - 'usos_pendientes' - 'updated_at') THEN
    NEW.updated_at = OLD.updated_at;
  ELSE
    NEW.updated_at = NOW();
  END IF;
  RETURN NEW;
END;
$function$;

-- =========================================================================
-- Poscondiciones
-- =========================================================================
DO $post$
DECLARE
  v_f text;
  v_c text := replace(pg_get_functiondef('public.guardar_combo(jsonb)'::regprocedure), E'\r\n', E'\n');
  v_p text := replace(pg_get_functiondef('public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'::regprocedure), E'\r\n', E'\n');
BEGIN
  IF position('''combo_cambiado''' in v_c) = 0 OR position('''orden_cambiado''' in v_c) = 0
     OR position('updated_at = now()' in v_c) = 0 OR position('FOR UPDATE' in v_c) = 0 THEN
    RAISE EXCEPTION 'mig NNN · el parche de guardar_combo no quedó';
  END IF;
  IF position('pg_advisory_xact_lock(hashtext(''guardar_combo'')' in v_c) = 0 OR position('v_vistos' in v_c) = 0 THEN
    RAISE EXCEPTION 'mig NNN · guardar_combo no quedó con la guarda del combo nuevo';
  END IF;
  IF position('CREATE TEMP TABLE IF NOT EXISTS' in v_c) > 0 OR position('DROP TABLE IF EXISTS pg_temp._combo_resuelto' in v_c) = 0
     OR (SELECT count(*) FROM regexp_matches(v_c, '([^._])_combo_resuelto', 'g')) > 0 THEN
    RAISE EXCEPTION 'mig NNN · guardar_combo sigue pudiendo usar la temporal de quien llama';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c
                  WHERE oid = 'public.update_promociones_updated_at()'::regprocedure AND c LIKE 'search_path=%pg_temp')
     OR NOT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c
                  WHERE oid = 'public.auditoria_funciones_modo_regalo_vivo()'::regprocedure AND c LIKE 'search_path=%pg_temp') THEN
    RAISE EXCEPTION 'mig NNN · una función reemplazada quedó sin pg_temp al final del search_path';
  END IF;
  IF position('''promocion_cambiada''' in v_p) = 0 OR position('ajuste_automatico, updated_at INTO v_promo' in v_p) = 0 THEN
    RAISE EXCEPTION 'mig NNN · el parche de cambiar_regalo_promocion no quedó';
  END IF;
  IF position('''crear_promocion''' in pg_get_functiondef('public.auditoria_funciones_modo_regalo_vivo()'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'mig NNN · crear_promocion no quedó en la lista de PROMO-C';
  END IF;
  FOREACH v_f IN ARRAY ARRAY['public.guardar_condicion_mayorista(jsonb)', 'public.crear_promocion(jsonb)',
                             'public.guardar_roles_extra(uuid,text[])', 'public.guardar_descuentos_categoria(bigint,jsonb)',
                             'public.guardar_combo(jsonb)', 'public.cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)'] LOOP
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_f::regprocedure) THEN
      RAISE EXCEPTION 'mig NNN · % no es SECURITY DEFINER', v_f;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c
                    WHERE oid = v_f::regprocedure AND c LIKE 'search_path=%' AND c LIKE '%pg_temp') THEN
      RAISE EXCEPTION 'mig NNN · % no tiene pg_temp al final del search_path', v_f;
    END IF;
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR NOT has_function_privilege('authenticated', v_f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc, aclexplode(proacl) a WHERE oid = v_f::regprocedure AND a.grantee = 0) THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para PUBLIC o anon, o sin él para authenticated', v_f;
    END IF;
  END LOOP;
  IF (SELECT count(*) FROM pg_proc WHERE pronamespace = 'public'::regnamespace
        AND proname IN ('guardar_combo', 'cambiar_regalo_promocion')) <> 2 THEN
    RAISE EXCEPTION 'mig NNN · quedó una sobrecarga de guardar_combo o de cambiar_regalo_promocion';
  END IF;
  -- v2: las de quien llama, las dos claves del cliente y el trigger de la versión.
  FOREACH v_f IN ARRAY ARRAY['public.guardar_cliente(jsonb)', 'public.guardar_usuario(jsonb)',
                             'public._alta_cliente_tomar_clave(uuid,text)', 'public._alta_cliente_cerrar_clave(uuid,bigint)',
                             'public.clientes_version()'] LOOP
    IF NOT EXISTS (SELECT 1 FROM pg_proc, unnest(proconfig) c
                    WHERE oid = v_f::regprocedure AND c LIKE 'search_path=%pg_temp') THEN
      RAISE EXCEPTION 'mig NNN · % no tiene pg_temp al final del search_path', v_f;
    END IF;
    IF has_function_privilege('anon', v_f, 'EXECUTE')
       OR EXISTS (SELECT 1 FROM pg_proc, aclexplode(proacl) a WHERE oid = v_f::regprocedure AND a.grantee = 0)
       OR has_function_privilege('authenticated', v_f, 'EXECUTE') = (v_f = 'public.clientes_version()') THEN
      RAISE EXCEPTION 'mig NNN · % quedó con un EXECUTE que no corresponde', v_f;
    END IF;
  END LOOP;
  IF (SELECT prosecdef FROM pg_proc WHERE oid = 'public.guardar_cliente(jsonb)'::regprocedure)
     OR (SELECT prosecdef FROM pg_proc WHERE oid = 'public.guardar_usuario(jsonb)'::regprocedure) THEN
    RAISE EXCEPTION 'mig NNN · guardar_cliente y guardar_usuario tienen que correr como quien llama';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_trigger WHERE tgrelid = 'public.clientes'::regclass
                   AND tgname = 'trg_clientes_zz_version' AND NOT tgisinternal) THEN
    RAISE EXCEPTION 'mig NNN · falta trg_clientes_zz_version';
  END IF;
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = 'public.altas_por_clave'::regclass)
     OR has_table_privilege('authenticated', 'public.altas_por_clave', 'SELECT')
     OR has_table_privilege('anon', 'public.altas_por_clave', 'SELECT')
     OR has_table_privilege('authenticated', 'public.altas_por_clave', 'INSERT')
     OR EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = 'public.altas_por_clave'::regclass) THEN
    RAISE EXCEPTION 'mig NNN · altas_por_clave no quedó sólo de server';
  END IF;
END
$post$;

COMMIT;
