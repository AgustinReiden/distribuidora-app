-- =========================================================================
-- NNN · UNA NOTA DE CRÉDITO DE COMPRA ANULADA NO CUENTA NI BLOQUEA LA COMPRA
--       (plan #1603, ola 2, tarjeta B18: H10 y H13 de la revisión de B2)
--
-- La 523 sumó `notas_credito.anulada` y la RPC `anular_nota_credito_compra`,
-- sin botón, porque varios lectores todavía contaban una nota anulada como
-- viva. Ésta cierra esos lectores, para que el front pueda ofrecer «Anular».
-- Ensayo: scripts/test-nc-compra-anulada-ola2-1603.sql. Se aplica en LF.
--
-- -------------------------------------------------------------------------
-- H10 · LO QUE SUMA NOTAS DEJA AFUERA LA ANULADA
-- -------------------------------------------------------------------------
--   · `posicion_fiscal`, `nc_k`: el IVA y el II de las notas de compra
--     restaban también los de una nota anulada. Una anulada no resta en
--     ningún período, tampoco en el de su fecha (la anulación deshace la nota,
--     no la «compensa» en el mes de la anulación).
--   · `reporte_gerencial`: «Compras del período» es neta de notas
--     (`compras_notas_credito`, en kpis y en mensual[]) y los ajustes suman a
--     «Descuentos de proveedores» (`desc_nc`). Los dos, sin las anuladas.
--   · `bot_compras_periodo`: la misma resta que el gerencial (D9 de #1557),
--     sin las anuladas. La revisión de B2 no la había listado.
--   Los dos primeros se parchan POR ANCLA con premisa de forma (el ancla
--   aparece exactamente N veces), no de md5: B16 trabaja en la misma tanda
--   sobre el tramo de las notas de VENTA de las mismas funciones. El resto,
--   con premisa de md5 del cuerpo vivo (producción en la 525).
--
-- -------------------------------------------------------------------------
-- H13 · UNA NOTA ANULADA NO DEJA LA COMPRA INMUTABLE
-- -------------------------------------------------------------------------
-- `actualizar_compra_items`, `anular_compra_atomica`, `cambiar_proveedor_compra`
-- y el trigger `compras_proteger_cancelacion` contaban toda nota, y una compra
-- con una nota anulada (la nota cargada en la compra equivocada, por ejemplo)
-- quedaba sin poder corregirse ni anularse nunca. La regla era que lo
-- acreditado ya había bajado el stock y los lotes de la compra, y editarla o
-- anularla lo restaba otra vez. Una nota anulada ya devolvió todo eso: el
-- stock, cada lote lo suyo, el promedio y la reposición; el promedio y el
-- arrastre ya la dejan afuera (`_cpp_arrastrar`, `_cpp_devolucion_compra`,
-- `_compra_producto_devuelto`, `sincronizar_lotes_compra`, mig 523). Así que
-- ahora sólo bloquean las notas vigentes. Lo que queda de una anulada es
-- historia (sus renglones, `lotes_tomados`): nada lo vuelve a aplicar, porque
-- una nota anulada no se reabre. Si la compra se cancela o se le cambia el
-- proveedor, la nota anulada queda en la compra original (cancelada), que es
-- de la que es comprobante (`notas_credito_proteger_vinculo` no la deja mudar).
--
-- Siguen contando toda nota, a propósito: `productos_rechazar_borrado_con_historial`
-- (un producto con una nota, anulada o no, tiene historia) y
-- `nota_credito_items_inmutable` (el comprobante no cambia).
--
-- No cambia firmas, tablas, datos ni permisos: sólo cuerpos de funciones (no
-- toma locks de tablas).
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
-- Premisas: la columna existe y los cuerpos vivos son los de la 525
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.columns
                  WHERE table_schema = 'public' AND table_name = 'notas_credito'
                    AND column_name = 'anulada' AND data_type = 'boolean' AND is_nullable = 'NO') THEN
    RAISE EXCEPTION 'mig NNN · falta notas_credito.anulada (boolean NOT NULL, mig 523)';
  END IF;

  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '87e8096b7c375c82b6bcf29a69026015'),
    ('public.anular_compra_atomica(bigint,uuid)',                           '4828b2bd18931117ccae0120f9461eb8'),
    ('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)',
     '3a631043bb168ce8545eb2005006b56d'),
    ('public.compras_proteger_cancelacion()',                              'b29827df1edeb24c263b45e9b8f9c52f'),
    ('public.bot_compras_periodo(date,date,bigint,integer)',               '87da9566b450098c9c84e1a097cdd8fe')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;

  -- posicion_fiscal y reporte_gerencial: premisa de forma (las anclas, abajo).
  IF to_regprocedure('public.posicion_fiscal(bigint,date,date)') IS NULL
     OR to_regprocedure('public.reporte_gerencial(bigint,date,date,boolean,boolean)') IS NULL THEN
    RAISE EXCEPTION 'mig NNN · posicion_fiscal o reporte_gerencial no tienen la firma esperada';
  END IF;
END
$premisas$;

-- La foto del definer y los permisos de cada función, para la poscondición.
CREATE TEMP TABLE b18_antes ON COMMIT DROP AS
SELECT p.oid AS fn, p.prosecdef AS def, p.proacl::text AS acl, p.proconfig::text AS cfg
  FROM pg_proc p
 WHERE p.oid IN ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'::regprocedure,
                 'public.anular_compra_atomica(bigint,uuid)'::regprocedure,
                 'public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure,
                 'public.compras_proteger_cancelacion()'::regprocedure,
                 'public.bot_compras_periodo(date,date,bigint,integer)'::regprocedure,
                 'public.posicion_fiscal(bigint,date,date)'::regprocedure,
                 'public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);

-- Reemplaza las p_n apariciones de un ancla en una definición.
CREATE FUNCTION pg_temp.parche(p_def text, p_ancla text, p_nuevo text, p_que text, p_n int DEFAULT 1)
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
-- H10 · posicion_fiscal (sólo `nc_k`, las notas de COMPRA)
-- =========================================================================
DO $parche_pf$
DECLARE
  v_def text := pg_get_functiondef('public.posicion_fiscal(bigint,date,date)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    WHERE nc.sucursal_id = ANY(v_sucursales)
      AND nc.fecha BETWEEN p_desde AND p_hasta
$a$,
$r$    WHERE nc.sucursal_id = ANY(v_sucursales)
      AND nc.fecha BETWEEN p_desde AND p_hasta
      AND NOT nc.anulada  /* mig NNN (B18, #1603): una nota de compra anulada no resta en ningún período */
$r$, 'posicion_fiscal (nc_k)');
  EXECUTE v_def;
END
$parche_pf$;

-- =========================================================================
-- H10 · reporte_gerencial (sólo las notas de COMPRA: k_compra, m_compra y desc_nc)
-- =========================================================================
DO $parche_rg$
DECLARE
  v_def text := pg_get_functiondef('public.reporte_gerencial(bigint,date,date,boolean,boolean)'::regprocedure);
BEGIN
  -- k_compra y m_compra: «Compras del período» neta de notas, en kpis y en mensual[].
  v_def := pg_temp.parche(v_def,
$a$WHERE ncp.sucursal_id = ANY(v_sucursales) AND ncp.fecha BETWEEN p_desde AND p_hasta
$a$,
$r$WHERE ncp.sucursal_id = ANY(v_sucursales) AND ncp.fecha BETWEEN p_desde AND p_hasta
        AND NOT ncp.anulada  /* mig NNN (B18, #1603): sin las notas de compra anuladas */
$r$, 'reporte_gerencial (k_compra y m_compra)', 2);
  -- desc_nc: los ajustes como «Descuentos de proveedores».
  v_def := pg_temp.parche(v_def,
$a$    WHERE nc.tipo = 'ajuste' AND nc.sucursal_id = ANY(v_sucursales)
$a$,
$r$    WHERE nc.tipo = 'ajuste' AND nc.sucursal_id = ANY(v_sucursales)
      AND NOT nc.anulada  /* mig NNN (B18, #1603): un ajuste anulado no es descuento */
$r$, 'reporte_gerencial (desc_nc)');
  EXECUTE v_def;
END
$parche_rg$;

-- =========================================================================
-- H10 · bot_compras_periodo
-- =========================================================================
DO $parche_bot$
DECLARE
  v_def text := pg_get_functiondef('public.bot_compras_periodo(date,date,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$      AND ncp.fecha >= p_desde AND ncp.fecha <= p_hasta
$a$,
$r$      AND ncp.fecha >= p_desde AND ncp.fecha <= p_hasta
      AND NOT ncp.anulada  /* mig NNN (B18, #1603): sin las notas anuladas, como el gerencial */
$r$, 'bot_compras_periodo (ncc)');
  EXECUTE v_def;
END
$parche_bot$;

-- =========================================================================
-- H13 · sólo las notas vigentes bloquean la compra
-- =========================================================================
DO $parche_h13$
DECLARE
  v_def text;
BEGIN
  v_def := pg_get_functiondef('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
$a$,
$r$  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     AND NOT anulada;  -- mig NNN (B18, H13): una nota anulada ya devolvió lo suyo y no bloquea
$r$, 'actualizar_compra_items (notas vigentes)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.anular_compra_atomica(bigint,uuid)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
$a$,
$r$  SELECT count(*) INTO v_nc_count
    FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     AND NOT anulada;  -- mig NNN (B18, H13): una nota anulada ya devolvió lo suyo y no bloquea
$r$, 'anular_compra_atomica (notas vigentes)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  SELECT count(*) INTO v_nc_count FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal;
$a$,
$r$  SELECT count(*) INTO v_nc_count FROM notas_credito
   WHERE compra_id = p_compra_id AND sucursal_id = v_sucursal
     AND NOT anulada;  -- mig NNN (B18, H13): la anulada queda en la original, que es de la que es comprobante
$r$, 'cambiar_proveedor_compra (notas vigentes)');
  EXECUTE v_def;

  v_def := pg_get_functiondef('public.compras_proteger_cancelacion()'::regprocedure);
  v_def := pg_temp.parche(v_def,
$a$  SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = OLD.id;
$a$,
$r$  -- mig NNN (B18, H13): sólo las notas vigentes; una anulada ya devolvió lo suyo.
  SELECT count(*) INTO v_n FROM notas_credito WHERE compra_id = OLD.id AND NOT anulada;
$r$, 'compras_proteger_cancelacion (notas vigentes)');
  EXECUTE v_def;
END
$parche_h13$;

-- ---------------------------------------------------------------------------
-- Poscondición: el parche entró, y el definer, los permisos y el search_path
-- quedaron como estaban
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  v_mal text := '';
BEGIN
  FOR r IN
    SELECT a.fn::regprocedure AS f, (p.prosecdef = a.def AND p.proacl::text IS NOT DISTINCT FROM a.acl
                                     AND p.proconfig::text IS NOT DISTINCT FROM a.cfg) AS igual
      FROM b18_antes a JOIN pg_proc p ON p.oid = a.fn
  LOOP
    IF NOT r.igual THEN
      v_mal := v_mal || format(E'\n  %s: cambió el definer, los permisos o el search_path', r.f);
    END IF;
  END LOOP;

  FOR r IN SELECT * FROM (VALUES
    ('public.posicion_fiscal(bigint,date,date)',
     'AND NOT nc.anulada  /* mig NNN (B18, #1603): una nota de compra anulada', 1),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',
     'AND NOT ncp.anulada  /* mig NNN (B18, #1603): sin las notas de compra anuladas */', 2),
    ('public.reporte_gerencial(bigint,date,date,boolean,boolean)',
     'AND NOT nc.anulada  /* mig NNN (B18, #1603): un ajuste anulado', 1),
    ('public.bot_compras_periodo(date,date,bigint,integer)', 'AND NOT ncp.anulada  /* mig NNN (B18', 1),
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     'AND NOT anulada;  -- mig NNN (B18, H13)', 1),
    ('public.anular_compra_atomica(bigint,uuid)', 'AND NOT anulada;  -- mig NNN (B18, H13)', 1),
    ('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)', 'AND NOT anulada;  -- mig NNN (B18, H13)', 1),
    ('public.compras_proteger_cancelacion()', 'WHERE compra_id = OLD.id AND NOT anulada;', 1)
  ) AS t(f, txt, n) LOOP
    IF (SELECT (length(prosrc) - length(replace(prosrc, r.txt, ''))) / length(r.txt)
          FROM pg_proc WHERE oid = r.f::regprocedure) <> r.n THEN
      v_mal := v_mal || format(E'\n  %s: «%s» no aparece %s vez/veces', r.f, r.txt, r.n);
    END IF;
  END LOOP;

  -- Las que tenían premisa de md5 quedan con el cuerpo del repo.
  FOR r IN SELECT * FROM (VALUES
    ('public.actualizar_compra_items(bigint,jsonb,numeric,numeric,numeric,uuid,numeric,numeric,numeric,numeric,numeric,jsonb,jsonb,numeric,bigint[])',
     '4d84f90bdb8f6c30ebcbf60aba74097c'),
    ('public.anular_compra_atomica(bigint,uuid)',                           'a0126c7c813395b6230f71b8560fba46'),
    ('public.cambiar_proveedor_compra(bigint,uuid,bigint,character varying,text)',
     '71e26b52a2f80f7937de28f8d27a0e5e'),
    ('public.compras_proteger_cancelacion()',                              'e807a8882c3e07cd4114b98b95e0bbec'),
    ('public.bot_compras_periodo(date,date,bigint,integer)',               '0748f03506c8c8cb301e12cce62c72c7')
  ) AS t(f, h) LOOP
    IF (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.f::regprocedure) IS DISTINCT FROM r.h THEN
      v_mal := v_mal || format(E'\n  %s: md5 %s, se esperaba %s', r.f,
                               (SELECT md5(prosrc) FROM pg_proc WHERE oid = r.f::regprocedure), r.h);
    END IF;
  END LOOP;

  IF v_mal <> '' THEN
    RAISE EXCEPTION 'mig NNN · no quedaron como en el repo:%', v_mal;
  END IF;
END
$post$;

COMMIT;
