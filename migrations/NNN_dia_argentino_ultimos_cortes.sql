-- ============================================================================
-- NNN · El día argentino: los últimos cortes en UTC (#1277)
-- ============================================================================
-- Tarjeta 4 del plan #1378. Aplicar desde el contenido LF.
-- Ensayo: scripts/test-dia-argentino-1277.sql.
--
-- QUÉ ES ESTO
-- -----------
-- La base corre en UTC: entre las 21 y las 24 de Argentina CURRENT_DATE ya es
-- mañana. De scripts/fechas-utc-permitidas.json quedaban siete funciones y cuatro
-- defaults, más auditoria_integridad() (VENTA-E), que es de la tarjeta 8 de #1308
-- y se queda en la lista.
--
-- Qué cambia a la noche, de acá en adelante. Las filas viejas no se tocan:
--   · crear_pedido_cambio_en_ruta: la comanda de un canje nace con el día
--     argentino, no con el siguiente.
--   · obtener_pedidos_ctacte_pendientes: los días de deuda dejan de sumar uno.
--   · bot_mis_clientes: lo mismo con los días sin compra y con su filtro.
-- Qué no cambia en nada que se vea hoy, y se pasa igual para achicar la lista:
--   · crear_recorrido: el front no la llama desde la 314 (arma la ruta con
--     aplicar_orden_ruta, que ya usa _tablero_hoy()).
--   · registrar_compra_completa: el front siempre manda la fecha, y con NULL el
--     INSERT choca contra el NOT NULL de compras.fecha_compra antes de llegar a
--     los dos COALESCE.
--   · deuda_previa_detalle y tablero_ficha_cliente: el created_at::date es el
--     segundo brazo de un COALESCE cuyo primero es NOT NULL. Medido en prod el
--     2026-11-02: pedidos, 7912 filas, 496 con created_at de 21 a 24 y 0 con fecha
--     NULL; pagos, 7545, 1269 y 0. Ninguna fila cambia de día ni se mueve ningún
--     número de esas pantallas.
--   · los cuatro defaults: registrar_nota_credito, registrar_nota_credito_lote,
--     registrar_ingreso_sucursal y crear_rendicion_por_fecha nombran la fecha en
--     su INSERT, y las compras entran por registrar_compra_completa. Sólo los
--     alcanza un INSERT que la omita.
--
-- QUÉ SE TOCA
-- -----------
-- Parcheadas por ancla sobre el cuerpo vivo, con md5 antes y después: el cuerpo
-- nuevo tiene que ser el viejo con ese reemplazo y nada más. Los atributos y los
-- EXECUTE no cambian. Molde: la 423.
-- Defaults de compras.fecha_compra, notas_credito.fecha, rendiciones.fecha y
-- transferencias_stock.fecha. rendiciones es del sistema viejo (#1368), pero sigue
-- existiendo y el gate la mira.
-- No se toca auditoria_integridad(), ni nada más de estas funciones.
-- ============================================================================

SET LOCAL lock_timeout = '5s';

-- ----------------------------------------------------------------------------
-- 0 · Premisas
-- ----------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
BEGIN
  -- "Ninguna fila cambia de día" descansa en estos dos NOT NULL.
  IF EXISTS (SELECT 1 FROM pg_attribute
              WHERE attrelid IN ('public.pedidos'::regclass, 'public.pagos'::regclass)
                AND attname = 'fecha' AND NOT attnotnull) THEN
    RAISE EXCEPTION 'pedidos.fecha o pagos.fecha aceptan NULL: medir de nuevo cuantas filas cambian de dia';
  END IF;

  FOR r IN SELECT * FROM (VALUES
      ('compras', 'fecha_compra'),
      ('notas_credito', 'fecha'),
      ('rendiciones', 'fecha'),
      ('transferencias_stock', 'fecha')) AS v(tabla, columna)
  LOOP
    IF (SELECT pg_get_expr(d.adbin, d.adrelid)
          FROM pg_attrdef d
          JOIN pg_attribute a ON a.attrelid = d.adrelid AND a.attnum = d.adnum
         WHERE d.adrelid = to_regclass('public.' || r.tabla) AND a.attname = r.columna)
       IS DISTINCT FROM 'CURRENT_DATE' THEN
      RAISE EXCEPTION 'el default de %.% no es el de prod del 2026-11-02: rehacer la migracion', r.tabla, r.columna;
    END IF;
  END LOOP;
END
$premisas$;

-- ----------------------------------------------------------------------------
-- 1 · Las funciones
-- ----------------------------------------------------------------------------
DO $parche$
DECLARE
  r       record;
  v_src   text;
  v_attrs text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
      ('public.bot_mis_clientes(uuid,bigint,boolean,integer,integer)',
       'e2c78addb653a56ae1c6b5925641b9bd',
       'CURRENT_DATE - b.ultima_compra',
       'public._tablero_hoy() - b.ultima_compra', 2),
      ('public.crear_pedido_cambio_en_ruta(integer,bigint,integer,bigint,integer,text,text)',
       '0d52312294d48eee73dafe3dd9793811',
       'p_cliente_id, CURRENT_DATE, ''pendiente''',
       'p_cliente_id, public._tablero_hoy(), ''pendiente''', 1),
      ('public.crear_recorrido(uuid,jsonb,numeric,integer)',
       '971461d2c44deb025182517b53b47907',
       'p_transportista_id, CURRENT_DATE, p_distancia',
       'p_transportista_id, public._tablero_hoy(), p_distancia', 1),
      ('public.deuda_previa_detalle(public.pedidos)',
       'c883e7bdb7283b6c87423b98d573580e',
       'COALESCE(p2.fecha, p2.created_at::date)',
       'COALESCE(p2.fecha, (p2.created_at AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date)', 1),
      ('public.obtener_pedidos_ctacte_pendientes(date,date,uuid)',
       '7524147bd47893279b0fa011cbe48434',
       '(CURRENT_DATE - (p.fecha_entrega AT TIME ZONE',
       '(public._tablero_hoy() - (p.fecha_entrega AT TIME ZONE', 1),
      ('public.registrar_compra_completa(bigint,character varying,character varying,date,numeric,numeric,numeric,numeric,character varying,text,uuid,jsonb,character varying,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,text)',
       '040d792fa9c9058dc4242e7a766e0829',
       'COALESCE(p_fecha_compra, CURRENT_DATE)',
       'COALESCE(p_fecha_compra, public._tablero_hoy())', 2),
      ('public.tablero_ficha_cliente(bigint)',
       '2c3df5031e0598282e8ad63cf75af915',
       'COALESCE(pg.fecha, pg.created_at::date)',
       'COALESCE(pg.fecha, (pg.created_at AT TIME ZONE ''America/Argentina/Buenos_Aires'')::date)', 1)
    ) AS v(firma, md5, viejo, nuevo, veces)
  LOOP
    SELECT prosrc, concat_ws('|', proowner, prosecdef, provolatile, proconfig::text, proacl::text)
      INTO v_src, v_attrs
      FROM pg_proc WHERE oid = to_regprocedure(r.firma);
    IF v_src IS NULL OR md5(v_src) <> r.md5 THEN
      RAISE EXCEPTION '% no es la de prod del 2026-11-02: rehacer el parche sobre la definicion viva', r.firma;
    END IF;
    IF (length(v_src) - length(replace(v_src, r.viejo, ''))) / length(r.viejo) <> r.veces THEN
      RAISE EXCEPTION '% no tiene % veces el corte que se reemplaza', r.firma, r.veces;
    END IF;
    EXECUTE replace(pg_get_functiondef(to_regprocedure(r.firma)), r.viejo, r.nuevo);
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> md5(replace(v_src, r.viejo, r.nuevo)) THEN
      RAISE EXCEPTION 'el parche de % cambio algo mas que el corte de dia', r.firma;
    END IF;
    IF (SELECT concat_ws('|', proowner, prosecdef, provolatile, proconfig::text, proacl::text)
          FROM pg_proc WHERE oid = to_regprocedure(r.firma)) <> v_attrs THEN
      RAISE EXCEPTION 'el parche de % cambio sus atributos o sus EXECUTE', r.firma;
    END IF;
  END LOOP;
END
$parche$;

-- ----------------------------------------------------------------------------
-- 2 · Los defaults
-- ----------------------------------------------------------------------------
-- Inline y no _tablero_hoy(): un default se evalúa con los permisos de quien
-- inserta. Es la misma expresión que pedidos.fecha.
ALTER TABLE public.compras
  ALTER COLUMN fecha_compra SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;
ALTER TABLE public.notas_credito
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;
ALTER TABLE public.rendiciones
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;
ALTER TABLE public.transferencias_stock
  ALTER COLUMN fecha SET DEFAULT ((now() AT TIME ZONE 'America/Argentina/Tucuman'))::date;

-- ----------------------------------------------------------------------------
-- 3 · Verificación
-- ----------------------------------------------------------------------------
DO $verif$
DECLARE
  v_g    jsonb := public.auditoria_fechas_utc();
  v_mias text[];
BEGIN
  SELECT array_agg(x->>'firma') INTO v_mias
    FROM jsonb_array_elements(v_g->'funciones') x
   WHERE x->>'nombre' IN ('bot_mis_clientes', 'crear_pedido_cambio_en_ruta', 'crear_recorrido',
                          'deuda_previa_detalle', 'obtener_pedidos_ctacte_pendientes',
                          'registrar_compra_completa', 'tablero_ficha_cliente');
  IF v_mias IS NOT NULL THEN
    RAISE EXCEPTION 'siguen cortando en UTC: %', v_mias;
  END IF;

  SELECT array_agg(x->>'columna') INTO v_mias
    FROM jsonb_array_elements(v_g->'defaults') x
   WHERE x->>'columna' IN ('compras.fecha_compra', 'notas_credito.fecha',
                           'rendiciones.fecha', 'transferencias_stock.fecha');
  IF v_mias IS NOT NULL THEN
    RAISE EXCEPTION 'siguen cortando en UTC: %', v_mias;
  END IF;
END
$verif$;
