-- 292 · El escáner aprende: equivalencias proveedor → producto
--
-- Escáner de facturas, Entrega B. Hasta acá el escaneo vinculaba una línea de
-- la factura sólo si el código impreso coincidía con `productos.codigo` o la
-- descripción era IDÉNTICA al nombre (`matchProductoEstricto`). Lo demás iba a
-- revisión humana y lo que el usuario decidía se perdía: la factura siguiente
-- del mismo proveedor volvía a preguntar lo mismo.
--
-- Esta migración guarda esas decisiones:
--
--   producto_equivalencias_proveedor · POR SUCURSAL (productos y proveedores lo
--     son). Una fila = "cuando el proveedor P imprime este código / esta
--     descripción, es nuestro producto X". Dos llaves, cualquiera alcanza:
--       - (sucursal, proveedor, codigo_proveedor) si la factura trae código;
--       - (sucursal, proveedor, descripcion_normalizada) siempre.
--     `unidades_por_bulto`: conversión para cuando el proveedor factura bultos y
--     nosotros stockeamos otra unidad (factura "1 caja", el producto es la
--     unidad suelta → 12). NULL = 1:1, que es el caso normal: en este catálogo
--     el producto suele SER el bulto ("AGUA ... 600 cc x 12" cuesta el pack).
--     NO es `productos.unidades_de_venta_por_fardo`: ésa (mig 031) es cuántas
--     unidades de VENTA hacen un fardo, sólo para imprimir "(1 FARDO)" en el
--     remito, y está cargada en un puñado de productos. Son dos datos distintos
--     y derivar uno del otro mezclaría la unidad de venta con la de compra.
--
--   normalizar_descripcion_proveedor(text) · la normalización de la llave. Tiene
--     un ESPEJO en TS (`normalizarDescripcion` de src/utils/matchEscaneo.ts) y
--     los dos tienen que dar lo mismo, o la descripción que el matcher busca no
--     es la que la RPC guardó y la equivalencia no se encuentra nunca, sin que
--     falle nada. Pasos, en este orden:
--       1. '#' → espacio (se usa como marcador en el paso 3);
--       2. acentos → sin acento con una lista EXPLÍCITA (translate, no
--          unaccent: unaccent depende de un diccionario y no es espejable letra
--          por letra en TS);
--       3. minúsculas;
--       4. coma o punto ENTRE dígitos → punto decimal ("2,25" y "2.25" dan
--          "2.25"); se marca con '#' para que el paso 5 no lo borre;
--       5. todo lo que no sea [a-z0-9#] → un espacio (colapsa las corridas);
--       6. '#' → '.', y trim.
--     "AGUA VILLAM. S/G 600X12" → "agua villam s g 600x12".
--     El código del proveedor se normaliza aparte y más simple: sin espacios y
--     en mayúsculas (`normalizarCodigoProveedor` en TS).
--
--   registrar_equivalencias_proveedor(p_proveedor_id, p_items) · la ÚNICA
--     escritura (la tabla no tiene policies de escritura). La llama el front
--     DESPUÉS de guardar la compra, sin bloquearla, como
--     `sincronizar_lotes_compra`: si falla, la compra queda y se avisa.
--     Upsert por lote; la última decisión gana (re-vincular cambia el
--     producto); `veces_usada` + 1 por cada confirmación.
--
--   candidatos_escaneo(p_proveedor_id) · SECURITY INVOKER: las equivalencias
--     del proveedor y los productos que ya se le compraron, con el último costo
--     unitario. Por ser INVOKER corre bajo la RLS de compras/compra_items, que
--     hoy sólo deja leer a admin y depósito: un encargado recibe las
--     equivalencias pero no el historial. Es lo que esa RLS decide, no un bug
--     de esta función.
--
-- Permisos (CLAUDE.md): las tres funciones nacen con EXECUTE para PUBLIC y
-- Supabase además se lo da a anon. Las dos RPCs se revocan de PUBLIC y anon y
-- se conceden a authenticated; la normalización sólo la llama la RPC definer
-- (que corre como su dueño), así que se revoca a las tres.

BEGIN;

-- -------------------------------------------------------------------------
-- 1 · Normalización (espejo de normalizarDescripcion en TS)
-- -------------------------------------------------------------------------
CREATE FUNCTION public.normalizar_descripcion_proveedor(p_texto text)
RETURNS text
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
SET search_path = ''
AS $fn$
  SELECT NULLIF(btrim(replace(
           regexp_replace(
             regexp_replace(
               lower(translate(replace(COALESCE(p_texto, ''), '#', ' '),
                 'ÁÀÄÂÃÉÈËÊÍÌÏÎÓÒÖÔÕÚÙÜÛÑÇáàäâãéèëêíìïîóòöôõúùüûñç',
                 'AAAAAEEEEIIIIOOOOOUUUUNCaaaaaeeeeiiiiooooouuuunc')),
               '([0-9])[.,]([0-9])', '\1#\2', 'g'),
             '[^a-z0-9#]+', ' ', 'g'),
           '#', '.')), '');
$fn$;

COMMENT ON FUNCTION public.normalizar_descripcion_proveedor(text) IS
  'Llave de descripcion de producto_equivalencias_proveedor (mig 292). Espejo exacto de normalizarDescripcion en src/utils/matchEscaneo.ts: si se cambia una, se cambia la otra.';

REVOKE EXECUTE ON FUNCTION public.normalizar_descripcion_proveedor(text) FROM PUBLIC, anon, authenticated;

-- -------------------------------------------------------------------------
-- 2 · La tabla
-- -------------------------------------------------------------------------
CREATE TABLE public.producto_equivalencias_proveedor (
  id                      bigint GENERATED BY DEFAULT AS IDENTITY PRIMARY KEY,
  sucursal_id             bigint NOT NULL REFERENCES public.sucursales(id),
  proveedor_id            bigint NOT NULL,
  producto_id             bigint NOT NULL,
  -- Ya normalizado (sin espacios, mayúsculas). NULL = la factura no trae código.
  codigo_proveedor        text NULL,
  descripcion_normalizada text NOT NULL,
  -- Tal como vino impresa la última vez, para mostrarla.
  descripcion_original    text NULL,
  -- NULL = 1:1. El tope descarta NaN (en numeric NaN es MAYOR que todo).
  unidades_por_bulto      numeric NULL,
  veces_usada             integer NOT NULL DEFAULT 1,
  ultimo_uso              timestamptz NOT NULL DEFAULT now(),
  creado_por              uuid NULL REFERENCES public.perfiles(id) ON DELETE SET NULL,
  created_at              timestamptz NOT NULL DEFAULT now(),
  updated_at              timestamptz NOT NULL DEFAULT now(),
  -- Compuestas: el aislamiento por sucursal (migs 186/187). Una simple dejaría
  -- apuntar una equivalencia de Tucumán a un producto de Taco Pozo.
  CONSTRAINT producto_equivalencias_proveedor_fk FOREIGN KEY (proveedor_id, sucursal_id)
    REFERENCES public.proveedores(id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT producto_equivalencias_producto_fk FOREIGN KEY (producto_id, sucursal_id)
    REFERENCES public.productos(id, sucursal_id) ON DELETE CASCADE,
  CONSTRAINT producto_equivalencias_codigo_no_vacio CHECK (codigo_proveedor IS NULL OR codigo_proveedor <> ''),
  CONSTRAINT producto_equivalencias_descripcion_no_vacia CHECK (descripcion_normalizada <> ''),
  CONSTRAINT producto_equivalencias_unidades_rango CHECK (unidades_por_bulto IS NULL OR (unidades_por_bulto > 0 AND unidades_por_bulto < 1000000)),
  CONSTRAINT producto_equivalencias_veces_no_negativas CHECK (veces_usada >= 0)
);

CREATE UNIQUE INDEX producto_equivalencias_codigo_uk
  ON public.producto_equivalencias_proveedor (sucursal_id, proveedor_id, codigo_proveedor)
  WHERE codigo_proveedor IS NOT NULL;
CREATE UNIQUE INDEX producto_equivalencias_descripcion_uk
  ON public.producto_equivalencias_proveedor (sucursal_id, proveedor_id, descripcion_normalizada);
CREATE INDEX producto_equivalencias_producto_idx
  ON public.producto_equivalencias_proveedor (producto_id);

COMMENT ON TABLE public.producto_equivalencias_proveedor IS
  'Escaner de facturas (mig 292): codigo/descripcion que imprime el proveedor -> nuestro producto. Se escribe sólo con registrar_equivalencias_proveedor, despues de guardar la compra.';
COMMENT ON COLUMN public.producto_equivalencias_proveedor.unidades_por_bulto IS
  'Unidades de NUESTRO producto por unidad facturada por el proveedor. NULL = 1:1. No es productos.unidades_de_venta_por_fardo (eso es para imprimir fardos en el remito).';

-- -------------------------------------------------------------------------
-- 3 · RLS. Leer: quien carga compras, de la sucursal activa. Escribir: sólo
--     por la RPC (no hay policies de escritura). anon: nada.
-- -------------------------------------------------------------------------
ALTER TABLE public.producto_equivalencias_proveedor ENABLE ROW LEVEL SECURITY;

CREATE POLICY producto_equivalencias_select ON public.producto_equivalencias_proveedor
  FOR SELECT TO authenticated USING (
    (public.es_admin() OR EXISTS (SELECT 1 FROM public.perfiles
                                   WHERE perfiles.id = auth.uid() AND perfiles.rol IN ('encargado', 'deposito')))
    AND sucursal_id = public.current_sucursal_id());

REVOKE ALL ON public.producto_equivalencias_proveedor FROM anon;
REVOKE INSERT, UPDATE, DELETE, TRUNCATE ON public.producto_equivalencias_proveedor FROM authenticated;

-- -------------------------------------------------------------------------
-- 4 · registrar_equivalencias_proveedor
--
-- p_items: [{ producto_id, codigo_proveedor?, descripcion, unidades_por_bulto? }]
--   - descripcion: tal como vino impresa; la normaliza la función.
--   - unidades_por_bulto: si la CLAVE no viene, se conserva el valor guardado
--     (salvo que cambie el producto: la conversión era del producto anterior y
--     vuelve a NULL). Si viene null, se borra. Así un llamador que no sabe de
--     conversiones (la pantalla de hoy) no pisa la que cargó otro.
--
-- Resolución de las dos llaves de una línea con código C y descripción D:
--   - ninguna fila tiene C ni D → se inserta;
--   - una fila tiene C (o D, si no hay fila con C) → se actualiza ésa: producto,
--     código y descripción toman lo último;
--   - C está en una fila y D en OTRA → las dos pasan a apuntar al producto
--     confirmado (la última decisión gana en las dos llaves).
-- -------------------------------------------------------------------------
CREATE FUNCTION public.registrar_equivalencias_proveedor(p_proveedor_id bigint, p_items jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $fn$
DECLARE
  v_sucursal    bigint := public.current_sucursal_id();
  v_item        jsonb;
  v_ord         bigint;
  v_prod        bigint;
  v_cod         text;
  v_orig        text;
  v_desc        text;
  v_tiene_upb   boolean;
  v_upb         numeric;
  v_fila_cod    bigint;
  v_fila_desc   bigint;
  v_fila        bigint;
  v_insertadas  integer := 0;
  v_actualizadas integer := 0;
BEGIN
  IF NOT (public.es_admin() OR EXISTS (
            SELECT 1 FROM public.perfiles WHERE id = auth.uid() AND rol IN ('encargado', 'deposito'))) THEN
    RAISE EXCEPTION 'Solo quien carga compras (admin, encargado o deposito) puede registrar equivalencias.'
      USING ERRCODE = '42501';
  END IF;
  IF v_sucursal IS NULL THEN
    RAISE EXCEPTION 'No hay sucursal activa.' USING ERRCODE = '22023';
  END IF;
  IF p_proveedor_id IS NULL OR NOT EXISTS (
       SELECT 1 FROM public.proveedores WHERE id = p_proveedor_id AND sucursal_id = v_sucursal) THEN
    RAISE EXCEPTION 'El proveedor % no es de la sucursal activa.', p_proveedor_id USING ERRCODE = '23503';
  END IF;
  IF p_items IS NULL OR jsonb_typeof(p_items) <> 'array' THEN
    RAISE EXCEPTION 'p_items tiene que ser un array.' USING ERRCODE = '22023';
  END IF;
  IF jsonb_array_length(p_items) > 500 THEN
    RAISE EXCEPTION 'Demasiadas líneas (máximo 500).' USING ERRCODE = '22023';
  END IF;

  FOR v_item, v_ord IN
    SELECT e.val, e.ord FROM jsonb_array_elements(p_items) WITH ORDINALITY AS e(val, ord) ORDER BY e.ord
  LOOP
    IF jsonb_typeof(v_item) <> 'object' THEN
      RAISE EXCEPTION 'La línea en la posición % no es un objeto.', v_ord - 1 USING ERRCODE = '22023';
    END IF;
    IF COALESCE(v_item->>'producto_id', '') !~ '^[0-9]{1,18}$' THEN
      RAISE EXCEPTION 'La línea en la posición % no tiene un producto_id válido.', v_ord - 1 USING ERRCODE = '22023';
    END IF;
    v_prod := (v_item->>'producto_id')::bigint;
    IF NOT EXISTS (SELECT 1 FROM public.productos WHERE id = v_prod AND sucursal_id = v_sucursal) THEN
      RAISE EXCEPTION 'El producto % no es de la sucursal activa.', v_prod USING ERRCODE = '23503';
    END IF;

    v_cod := CASE WHEN jsonb_typeof(v_item->'codigo_proveedor') IN ('string', 'number')
                  THEN NULLIF(upper(regexp_replace(v_item->>'codigo_proveedor', '\s+', '', 'g')), '') END;
    v_orig := NULLIF(btrim(COALESCE(v_item->>'descripcion', '')), '');
    v_desc := public.normalizar_descripcion_proveedor(v_orig);
    IF v_desc IS NULL THEN
      RAISE EXCEPTION 'La línea en la posición % no tiene descripción.', v_ord - 1 USING ERRCODE = '22023';
    END IF;

    v_tiene_upb := v_item ? 'unidades_por_bulto';
    v_upb := NULL;
    IF v_tiene_upb AND jsonb_typeof(v_item->'unidades_por_bulto') <> 'null' THEN
      IF jsonb_typeof(v_item->'unidades_por_bulto') <> 'number'
         OR NOT ((v_item->>'unidades_por_bulto')::numeric > 0 AND (v_item->>'unidades_por_bulto')::numeric < 1000000) THEN
        RAISE EXCEPTION 'La línea en la posición % tiene unidades_por_bulto que no es un número mayor que 0.', v_ord - 1
          USING ERRCODE = '22023';
      END IF;
      v_upb := (v_item->>'unidades_por_bulto')::numeric;
    END IF;

    v_fila_cod := NULL;
    v_fila_desc := NULL;
    IF v_cod IS NOT NULL THEN
      SELECT id INTO v_fila_cod FROM public.producto_equivalencias_proveedor
       WHERE sucursal_id = v_sucursal AND proveedor_id = p_proveedor_id AND codigo_proveedor = v_cod
       FOR UPDATE;
    END IF;
    SELECT id INTO v_fila_desc FROM public.producto_equivalencias_proveedor
     WHERE sucursal_id = v_sucursal AND proveedor_id = p_proveedor_id AND descripcion_normalizada = v_desc
     FOR UPDATE;

    IF v_fila_cod IS NULL AND v_fila_desc IS NULL THEN
      -- DO NOTHING: si otra sesión insertó la misma llave en el medio, su
      -- decisión vale tanto como ésta, y la llamada no bloquea nada.
      INSERT INTO public.producto_equivalencias_proveedor
        (sucursal_id, proveedor_id, producto_id, codigo_proveedor, descripcion_normalizada,
         descripcion_original, unidades_por_bulto, veces_usada, ultimo_uso, creado_por)
      VALUES (v_sucursal, p_proveedor_id, v_prod, v_cod, v_desc, v_orig, v_upb, 1, now(), auth.uid())
      ON CONFLICT DO NOTHING;
      IF FOUND THEN v_insertadas := v_insertadas + 1; END IF;
      CONTINUE;
    END IF;

    v_fila := COALESCE(v_fila_cod, v_fila_desc);
    UPDATE public.producto_equivalencias_proveedor SET
      unidades_por_bulto = CASE WHEN v_tiene_upb THEN v_upb
                                WHEN producto_id <> v_prod THEN NULL
                                ELSE unidades_por_bulto END,
      producto_id = v_prod,
      -- En la fila del código no cambia; en la de la descripción (sin fila del
      -- código) el código nuevo está libre y gana.
      codigo_proveedor = COALESCE(v_cod, codigo_proveedor),
      -- La descripción sólo se mueve si D no la tiene otra fila.
      descripcion_normalizada = CASE WHEN v_fila_desc IS NULL THEN v_desc ELSE descripcion_normalizada END,
      descripcion_original = CASE WHEN v_fila_desc IS NULL OR v_fila_desc = v_fila THEN v_orig ELSE descripcion_original END,
      veces_usada = veces_usada + 1,
      ultimo_uso = now(),
      updated_at = now()
     WHERE id = v_fila;

    IF v_fila_desc IS NOT NULL AND v_fila_desc <> v_fila THEN
      UPDATE public.producto_equivalencias_proveedor SET
        unidades_por_bulto = CASE WHEN v_tiene_upb THEN v_upb
                                  WHEN producto_id <> v_prod THEN NULL
                                  ELSE unidades_por_bulto END,
        producto_id = v_prod,
        descripcion_original = v_orig,
        ultimo_uso = now(),
        updated_at = now()
       WHERE id = v_fila_desc;
    END IF;
    v_actualizadas := v_actualizadas + 1;
  END LOOP;

  RETURN jsonb_build_object('success', true, 'insertadas', v_insertadas, 'actualizadas', v_actualizadas);
END;
$fn$;

COMMENT ON FUNCTION public.registrar_equivalencias_proveedor(bigint, jsonb) IS
  'Escaner (mig 292): guarda las equivalencias que el usuario confirmo en una compra. Se llama despues de registrarla, sin bloquearla.';

REVOKE EXECUTE ON FUNCTION public.registrar_equivalencias_proveedor(bigint, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_equivalencias_proveedor(bigint, jsonb) TO authenticated;

-- -------------------------------------------------------------------------
-- 5 · candidatos_escaneo (SECURITY INVOKER: corre bajo la RLS de quien llama)
--
-- comprados: un renglón por producto comprado a este proveedor en la sucursal
-- activa (compras no canceladas). El último costo es el de la última compra
-- con costo > 0: una línea bonificada a $0 no es el precio del producto.
-- -------------------------------------------------------------------------
CREATE FUNCTION public.candidatos_escaneo(p_proveedor_id bigint)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY INVOKER
SET search_path = public
AS $fn$
  WITH suc AS (
    SELECT public.current_sucursal_id() AS id
  ),
  eq AS (
    SELECT e.*
      FROM public.producto_equivalencias_proveedor e, suc
     WHERE e.sucursal_id = suc.id AND e.proveedor_id = p_proveedor_id
  ),
  lineas AS (
    SELECT ci.producto_id, ci.costo_unitario, c.fecha_compra, c.id AS compra_id, ci.id AS item_id,
           count(*) OVER (PARTITION BY ci.producto_id) AS veces
      FROM public.compras c
      JOIN public.compra_items ci ON ci.compra_id = c.id
      CROSS JOIN suc
     WHERE c.sucursal_id = suc.id
       AND ci.sucursal_id = suc.id
       AND c.proveedor_id = p_proveedor_id
       AND c.estado IS DISTINCT FROM 'cancelada'
  ),
  comprados AS (
    SELECT DISTINCT ON (producto_id)
           producto_id, NULLIF(costo_unitario, 0) AS ultimo_costo, fecha_compra, veces
      FROM lineas
     ORDER BY producto_id, (costo_unitario > 0) DESC, fecha_compra DESC, compra_id DESC, item_id DESC
  )
  SELECT jsonb_build_object(
    'equivalencias', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'producto_id', eq.producto_id,
               'codigo_proveedor', eq.codigo_proveedor,
               'descripcion_normalizada', eq.descripcion_normalizada,
               'descripcion_original', eq.descripcion_original,
               'unidades_por_bulto', eq.unidades_por_bulto,
               'veces_usada', eq.veces_usada,
               'ultimo_uso', eq.ultimo_uso) ORDER BY eq.id)
        FROM eq), '[]'::jsonb),
    'comprados', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'producto_id', comprados.producto_id,
               'ultimo_costo_unitario', comprados.ultimo_costo,
               'ultima_fecha', comprados.fecha_compra,
               'veces_comprado', comprados.veces) ORDER BY comprados.producto_id)
        FROM comprados), '[]'::jsonb));
$fn$;

COMMENT ON FUNCTION public.candidatos_escaneo(bigint) IS
  'Escaner (mig 292): equivalencias del proveedor y productos que ya se le compraron (ultimo costo unitario), de la sucursal activa. SECURITY INVOKER: respeta la RLS de compras.';

REVOKE EXECUTE ON FUNCTION public.candidatos_escaneo(bigint) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.candidatos_escaneo(bigint) TO authenticated;

-- -------------------------------------------------------------------------
-- 6 · Ensayo de la normalización: los casos del espejo en TS
--     (src/utils/matchEscaneo.test.ts usa la misma tabla).
-- -------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_casos text[][] := ARRAY[
    ['AGUA VILLAM. S/G 600X12', 'agua villam s g 600x12'],
    ['MANAOS COLA 2,25 LT',     'manaos cola 2.25 lt'],
    ['Coca-Cola  Zero 1.5Lts x 6', 'coca cola zero 1.5lts x 6'],
    ['AZÚCAR LEDESMA x 1 KG.',  'azucar ledesma x 1 kg'],
    ['  Ñoquis #3 (500grs) ',   'noquis 3 500grs'],
    ['1.2.3',                   '1.2 3'],
    ['PAÑAL. ',                 'panal']
  ];
  v_obs text;
  i int;
BEGIN
  FOR i IN 1 .. array_length(v_casos, 1) LOOP
    v_obs := public.normalizar_descripcion_proveedor(v_casos[i][1]);
    IF v_obs IS DISTINCT FROM v_casos[i][2] THEN
      RAISE EXCEPTION 'mig292 · normalizar(%) = %, esperado %', v_casos[i][1], v_obs, v_casos[i][2];
    END IF;
  END LOOP;
  IF public.normalizar_descripcion_proveedor(' .,- ') IS NOT NULL THEN
    RAISE EXCEPTION 'mig292 · una descripcion sin letras ni numeros tiene que normalizar a NULL';
  END IF;
  RAISE NOTICE 'mig292 · normalizacion OK (% casos)', array_length(v_casos, 1);
END
$ensayo$;

COMMIT;
