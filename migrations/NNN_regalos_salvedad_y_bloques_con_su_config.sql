-- =========================================================================
-- NNN · REGALOS Y SALVEDAD: CADA BLOQUE DE LA BARRA SE DESHACE CON SU
--       CONFIGURACIÓN, LA SALVEDAD SOBRE LA VENTA BAJA EL CORTE GUARDADO Y
--       LA SALVEDAD SÓLO VA SOBRE UN PEDIDO EN CAMINO O ENTREGADO
--       (ola 2 del plan #1603, tarjeta B1: el residual de PRM-2 de #1592
--        —H6 de la revisión de la 512—, 1583-a, 1595-b5 y 1564-b2)
--
-- Agrega cuatro columnas a `promo_ajustes`; parcha por ancla
-- `aplicar_uso_promo_acumulador`, `renormalizar_bloques_por_cambio_factor`,
-- `_contenedores_de_promos`, `registrar_salvedad` y las dos simulaciones de
-- salvedad, con premisa de md5 sobre el cuerpo vivo del 16/11 (ledger en la
-- 512); rehace `_regalo_recorte` (suma una columna a lo que devuelve) y crea
-- una regla pura de server. Anota los bloques que las barras ya tienen
-- cerrados (datos). No cambia firmas de RPC.
-- Ensayo: scripts/test-regalos-salvedad-ola2-1603.sql. Se aplica en LF.
--
-- =========================================================================
-- 1 · H6 · CADA BLOQUE DE LA BARRA SE DESHACE CON LA CONFIGURACIÓN CON LA QUE
--     SE CERRÓ
-- =========================================================================
-- `aplicar_uso_promo_acumulador` deshacía los bloques con el factor, el stock
-- por bloque y el contenedor de HOY. La guarda de la 512 no deja cambiarlos con
-- pedidos sin entregar, pero un pedido entregado sigue admitiendo salvedad: con
-- un factor 6 → 4 de por medio, dos salvedades del regalo entero dejaban el
-- contenedor en 51 en vez de 50 y PROMO-A en rojo (H6). El arreglo de fondo
-- acordado es deshacer cada bloque con la configuración con la que se armó.
--   · La barra es compartida: un bloque junta unidades de varios pedidos, y
--     un pedido reparte las suyas entre bloques y el resto. Por eso la
--     configuración se guarda en el BLOQUE, no en el pedido: la línea sólo
--     tiene su factor (`unidades_por_bloque_al_crear`), y deshacer con ése
--     deja el resto de la barra corrido cuando el bloque de arriba se cerró
--     con otro (un bloque de 4 deshecho como de 6 deja 2 unidades fantasma).
--   · `promo_ajustes` ya es la pila de bloques de cada (promo, contenedor):
--     ahora la fila que cierra bloques anota de qué barra es
--     (`barra_regalo_id`: el regalo de la barra, el mismo id que la rotación
--     conserva), cuántas unidades y cuánto stock tiene cada bloque
--     (`usos_por_bloque`, `stock_por_bloque`) y cuántos siguen cerrados
--     (`bloques_vivos`). La escriben `aplicar_uso_promo_acumulador` y
--     `renormalizar_bloques_por_cambio_factor`, las dos únicas que escriben
--     la tabla, con la promo tomada.
--   · Bajar la barra por debajo de 0 abre los bloques vivos de esa barra del
--     último al primero, cada uno con sus unidades y su stock, y el fardo
--     vuelve al contenedor del que salió (aunque hoy la barra tenga otro). Si
--     lo que queda en la barra pasa el factor de hoy, se vuelve a cerrar con
--     la configuración de hoy, en el mismo movimiento: en el contenedor de hoy
--     se mueve sólo la diferencia (una subida que se compensa con una bajada
--     del mismo producto no va a ningún lado, migrations/CLAUDE.md). Así la
--     barra sigue en [0, factor) y lo que el cliente se quedó tiene su fardo.
--   · Una baja de la barra (salvedad, cancelación, edición a la baja) nunca
--     falla por falta de stock (H1 de la revisión): ese recierre se limita a
--     lo que el contenedor de hoy tiene, más lo que el mismo movimiento le
--     devuelve, y el resto queda en la barra aunque pase del factor. La
--     próxima venta lo cierra con su FLOOR.
--   · Un bloque cerrado antes de esta migración no tiene el dato: abajo se
--     anotan los que cada barra tiene cerrados, con la configuración de hoy
--     (la del día en que se anotan), en una fila sin unidades ni stock (lo que
--     haría la cuenta vieja, pero congelado: un cambio de factor posterior ya
--     no los toca). Eso es exacto sólo si la promo nunca cambió de factor, ni
--     de contenedor, y si ninguna barra comparte contenedor con otra: una
--     premisa aborta la migración si al aplicarla no es así (H3 de la
--     revisión; al 17/11 en prod no hay ningún caso). Un bloque sin anotar
--     sigue con la cuenta de hoy, con un tope: nunca devuelve a un contenedor
--     más fardos de los que la promo le sacó y siguen sin dueño en la pila
--     (la cuenta de PROMO-A). Lo que pasa el tope se pierde en la barra, que
--     queda en 0, como ya hacía el piso de la barra default.
--   · `_contenedores_de_promos` suma los contenedores de los bloques vivos:
--     la salvedad, la cancelación, la edición y el resto toman con ella los
--     productos antes que la promo (#1375, #1460), y un bloque viejo puede
--     volver a un contenedor que ya no es el de la barra.
-- La guarda `trg_promo_config_barra_con_pedidos` (512, decisión del dueño D2)
-- no cambia: ya no hace falta para que cierre el contenedor, pero es la regla
-- del dueño, y aflojarla es decisión suya.
--
-- =========================================================================
-- 2 · 1583-a · LA SALVEDAD SOBRE LA VENTA BAJA EL CORTE GUARDADO
-- =========================================================================
-- Desde la 500 cada regalo guarda su corte (`pedido_items.regalo_corte`, lo
-- que cuenta el cupo), pero la salvedad sobre la venta medía el regalo con la
-- cuenta deducida de la cantidad (`regalo_usos_de_linea`). Con un cambio por
-- valor que achica (R×10 → W×1) y una edición a más (V×14: W×1 con corte 14),
-- una salvedad de 4 V no recortaba nada (W×1 se deshace en 10) y el corte
-- quedaba en 14.
--   · `registrar_salvedad` (el exceso) y `_regalo_recorte` (el corte de cada
--     línea) leen el corte guardado; sin corte, la cuenta deducida.
--   · El recorte escribe el corte nuevo con `app.regalo_corte_manual`, aunque
--     la cantidad de la línea no cambie (W×1 sigue W×1 con corte 10).
--     `_regalo_recorte` devuelve también esas líneas, con `corte_final`.
--   · Las dos simulaciones miden igual (`_regalo_corte_tras_cantidad`: el
--     corte que la línea tendría después de la salvedad del lote sobre el
--     regalo mismo, la cuenta de `sellar_corte_regalo_item`).
--   · `anular_salvedad` cuenta como recorte también una baja de
--     `regalo_corte` (H2 de la revisión): un recorte que sólo baja el corte
--     es un recorte, y anularlo se rechaza como cualquier otro (1592-b5).
--     Si no, la anulación devolvía la venta y el corte quedaba bajo, y el
--     cupo de la promo dejaba pasar de más. Se parcha por ancla y sin md5:
--     otra tarjeta de la ola la toca antes.
-- Lo que ve el usuario no cambia: la cantidad de la línea es la misma de
-- antes; sólo el cupo deja de contar de más.
--
-- =========================================================================
-- 3 · 1595-b5 · LA SALVEDAD VA SOBRE UN PEDIDO EN CAMINO O ENTREGADO
-- =========================================================================
-- Decisión del dueño (D23, en #1595): una salvedad se registra sólo sobre un
-- pedido en reparto o entregado. `registrar_salvedad` rechaza uno pendiente o
-- en preparación (`pedido_sin_salir`). El front sólo ofrece la salvedad en
-- `asignado` ("En camino") o sobre uno entregado.
--
-- =========================================================================
-- 4 · 1564-b2 · LA NC VIGENTE SE LEE DESPUÉS DE ACOTAR LA SUCURSAL
-- =========================================================================
-- `registrar_salvedad` buscaba la NC vigente del pedido antes de mirar si el
-- pedido era de la sucursal activa: un admin de la 1 leía "NC #38 vigente" de
-- un pedido de la 2. Ahora un pedido que no es de la sucursal activa contesta
-- "Pedido no encontrado" antes de leer nada de él.
-- =========================================================================

BEGIN;

SET LOCAL lock_timeout = '5s';
-- La única tabla con DDL (H4 de la revisión): el lock va antes de todo y sin esperar.
LOCK TABLE public.promo_ajustes IN ACCESS EXCLUSIVE MODE NOWAIT;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'el texto de la migración trae CRLF: aplicarla desde la versión LF';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- Premisas: los cuerpos vivos del 16/11 (ledger en la 512)
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  r record;
  v text;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', '6386b01d78e5b1d7ceb9e98ddda6941e'),
    ('public.renormalizar_bloques_por_cambio_factor()', 'a10d7e1cc73030707b47e572fb869caa'),
    ('public._contenedores_de_promos(bigint[],bigint)', 'cab70e87a44a94a366f9a4b6ec7e42eb'),
    ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', '4d5fd79e669f045c8a3decc1c74387c7'),
    ('public._regalo_recorte(bigint,bigint,bigint,numeric,jsonb)', '5048b2c28bae5f713dd22b7ccca8ffd2'),
    ('public.simular_salvedad_promo_impacto(bigint,bigint,integer)', '3ede7dcd8682f7b666fa02263cf142f0'),
    ('public.simular_salvedades_promo_impacto(bigint,jsonb)', 'f4ee4cc3d283523e4bd8f6777a4679a7'),
    -- No cambian, pero las cuentas nuevas cuentan con ellas como están.
    ('public.regalo_usos_de_linea(jsonb,uuid,numeric)', 'ef688c68401e8f44d923c3d24d857b48'),
    ('public.regalo_sustitucion_resuelta(bigint,bigint,bigint,bigint,numeric,uuid)', '350bd139b8f9f255babc4380337b2a04'),
    ('public.regalo_eslabones(bigint,bigint,bigint)', '437bf430517266331c4f55102811014b'),
    ('public.regalo_raiz_de_eslabones(jsonb,bigint,uuid)', '526e0a4d2bf1fbb2ae6c7023708af8d5'),
    ('public.sellar_corte_regalo_item()', 'fa5740d521e0e61d9c6760aa61ee25aa'),
    ('public._mov_lotes_foto(bigint,bigint)', '6ca074b808d19facff8d224da4a97a5a'),
    ('public._mov_lotes_diff(bigint,bigint,jsonb,integer)', '087b6a5e247316cfb1128d15d5294f10'),
    ('public._mov_lotes_devolver(bigint,jsonb)', '83ef22b3b0143bf318ead07069ac916e')
  ) AS t(f, h) LOOP
    IF to_regprocedure(r.f) IS NULL THEN
      RAISE EXCEPTION 'mig NNN · % no existe: rehacer sobre lo vigente', r.f;
    END IF;
    SELECT md5(prosrc) INTO v FROM pg_proc WHERE oid = r.f::regprocedure;
    IF v IS DISTINCT FROM r.h THEN
      RAISE EXCEPTION 'mig NNN · % cambió desde que se leyó (md5 %): rehacer sobre el cuerpo vigente', r.f, v;
    END IF;
  END LOOP;
  IF to_regproc('public._regalo_corte_tras_cantidad') IS NOT NULL
     OR EXISTS (SELECT 1 FROM pg_attribute WHERE attrelid = 'public.promo_ajustes'::regclass
                 AND attname IN ('barra_regalo_id', 'usos_por_bloque', 'stock_por_bloque', 'bloques_vivos')
                 AND NOT attisdropped) THEN
    RAISE EXCEPTION 'mig NNN · la función o las columnas nuevas ya existen: revisar a mano';
  END IF;
  -- H2: el ancla de anular_salvedad. Sin md5: otra tarjeta de la ola la parcha antes.
  IF position($ancla$                      AND (f.accion = 'DELETE'
                           OR (f.new_data->>'cantidad')::numeric < (f.old_data->>'cantidad')::numeric))$ancla$
              IN (SELECT prosrc FROM pg_proc
                   WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure)) = 0 THEN
    RAISE EXCEPTION 'mig NNN · anular_salvedad ya no tiene la detección de recortes de 1592-b5 como se leyó: rehacer el parche';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- Premisa de datos (H3 de la revisión): el bloque de datos de 1e anota los
-- bloques ya cerrados con la configuración de hoy y en el contenedor de hoy de
-- cada barra. Es exacto sólo si no hay fardos afuera en un contenedor que ya no
-- es de ninguna barra de su promo, si ninguna promo cambió de factor y si
-- ninguna barra comparte contenedor con otra de su promo. Al 17/11 en prod no
-- hay ningún caso. Si aparece uno, se decide ahí (con el dueño) qué hacer con
-- esos fardos antes de aplicar.
-- ---------------------------------------------------------------------------
DO $premisa_datos$
DECLARE
  v_anterior   text;
  v_factor     text;
  v_comparten  text;
BEGIN
  SELECT left(string_agg(format('promo %s contenedor %s (%s fardos)', x.promocion_id, x.producto_id, x.neto), ', '), 300)
    INTO v_anterior
    FROM (SELECT pa.promocion_id, pa.producto_id, SUM(pa.unidades_ajustadas) AS neto
            FROM public.promo_ajustes pa
            JOIN public.promociones p ON p.id = pa.promocion_id AND p.sucursal_id = pa.sucursal_id
           WHERE pa.producto_id IS NOT NULL
             AND pa.producto_id IS DISTINCT FROM p.ajuste_producto_id
             AND NOT EXISTS (SELECT 1 FROM public.promo_acumuladores a
                              WHERE a.promocion_id = pa.promocion_id AND a.sucursal_id = pa.sucursal_id
                                AND a.ajuste_producto_id = pa.producto_id)
           GROUP BY 1, 2
          HAVING SUM(pa.unidades_ajustadas) > 0) x;
  SELECT left(string_agg(DISTINCT pa.promocion_id::text, ', '), 300) INTO v_factor
    FROM public.promo_ajustes pa
   WHERE pa.observaciones LIKE 'Cambio de factor:%';
  SELECT left(string_agg(format('promo %s contenedor %s', y.promo, y.cont), ', '), 300) INTO v_comparten
    FROM (SELECT b.promo, b.cont
    FROM (SELECT p.id AS promo, p.sucursal_id AS suc, p.ajuste_producto_id AS cont
            FROM public.promociones p
           WHERE p.producto_regalo_id IS NOT NULL AND p.ajuste_producto_id IS NOT NULL
             AND p.regalo_mueve_stock IS FALSE AND COALESCE(p.ajuste_automatico, false)
             AND COALESCE(p.unidades_por_bloque, 0) > 0 AND COALESCE(p.stock_por_bloque, 0) > 0
          UNION ALL
          SELECT p.id, p.sucursal_id, a.ajuste_producto_id
            FROM public.promo_acumuladores a
            JOIN public.promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
           WHERE a.ajuste_producto_id IS NOT NULL
             AND a.producto_regalo_id IS DISTINCT FROM p.producto_regalo_id
             AND p.regalo_mueve_stock IS FALSE AND COALESCE(p.ajuste_automatico, false)
             AND COALESCE(p.unidades_por_bloque, 0) > 0 AND COALESCE(p.stock_por_bloque, 0) > 0) b
   GROUP BY b.promo, b.suc, b.cont
  HAVING count(*) > 1) y;
  IF v_anterior IS NOT NULL OR v_factor IS NOT NULL OR v_comparten IS NOT NULL THEN
    RAISE EXCEPTION 'mig NNN · los bloques ya cerrados no se pueden anotar con exactitud: fardos en un contenedor anterior [%]; promos que cambiaron de factor [%]; barras que comparten contenedor [%]. Decidir qué hacer con ellos antes de aplicar.',
      COALESCE(v_anterior, '-'), COALESCE(v_factor, '-'), COALESCE(v_comparten, '-');
  END IF;
END
$premisa_datos$;

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

-- El tramo de una definición que va desde `p_desde` (incluido) hasta `p_hasta`
-- (excluido). Las dos marcas aparecen una sola vez, en ese orden.
CREATE FUNCTION pg_temp.tramo(p_def text, p_desde text, p_hasta text, p_que text)
RETURNS text LANGUAGE plpgsql AS $f$
DECLARE
  v_i int := position(p_desde in p_def);
  v_j int := position(p_hasta in p_def);
BEGIN
  IF (length(p_def) - length(replace(p_def, p_desde, ''))) / length(p_desde) <> 1
     OR (length(p_def) - length(replace(p_def, p_hasta, ''))) / length(p_hasta) <> 1
     OR v_j <= v_i THEN
    RAISE EXCEPTION 'mig NNN · %: las marcas del tramo no aparecen una vez cada una y en orden', p_que;
  END IF;
  RETURN substr(p_def, v_i, v_j - v_i);
END
$f$;

-- =========================================================================
-- 1 · H6 · la pila de bloques en promo_ajustes
-- =========================================================================
-- Sin freno de NaN: son integer. Legibles como el resto de la tabla (SELECT de
-- tabla para authenticated, con sus policies): no dicen nada que la fila no
-- dijera ya.
ALTER TABLE public.promo_ajustes
  ADD COLUMN barra_regalo_id  bigint,
  ADD COLUMN usos_por_bloque  integer,
  ADD COLUMN stock_por_bloque integer,
  ADD COLUMN bloques_vivos    integer,
  ADD CONSTRAINT promo_ajustes_bloque_coherente CHECK (
    (usos_por_bloque IS NULL AND stock_por_bloque IS NULL AND bloques_vivos IS NULL)
    OR (usos_por_bloque > 0 AND stock_por_bloque > 0 AND bloques_vivos >= 0));

COMMENT ON COLUMN public.promo_ajustes.barra_regalo_id IS
  'mig NNN (#1592 H6): la barra que cerró los bloques de esta fila (el regalo de la barra: el de la promo o el de su fila de promo_acumuladores).';
COMMENT ON COLUMN public.promo_ajustes.bloques_vivos IS
  'mig NNN (#1592 H6): cuántos bloques de esta fila siguen cerrados. Deshacer la barra los abre del último al primero, cada uno con usos_por_bloque y stock_por_bloque, y el fardo vuelve a producto_id.';

CREATE INDEX promo_ajustes_bloques_vivos_idx
  ON public.promo_ajustes (promocion_id, barra_regalo_id, id DESC)
  WHERE bloques_vivos > 0;

-- =========================================================================
-- 1b · aplicar_uso_promo_acumulador: abre los bloques con su configuración
-- =========================================================================
DO $parche_acumulador$
DECLARE
  v_def  text := pg_get_functiondef('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)'::regprocedure);
  v_cola text;
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  t                RECORD;
  e                RECORD;
BEGIN
$a$,
$r$  t                RECORD;
  e                RECORD;
  -- mig NNN (#1592 H6): la pila de bloques y los movimientos por contenedor.
  m                RECORD;
  v_movs           JSONB;
  v_falta          NUMERIC;
  v_k              INT;
  v_cierra         INT;
  v_abiertos       INT;
  v_neto           BIGINT;
  v_vivos          BIGINT;
  v_ya             BIGINT;
  v_obs_fila       TEXT;
BEGIN
$r$, 'aplicar_uso_promo_acumulador (declaraciones)');

  v_cola := pg_temp.tramo(v_def,
$d$  v_usos_raw := v_resto_actual + p_delta;
$d$,
$h$END;
$function$$h$, 'aplicar_uso_promo_acumulador (la cuenta de bloques)');

  v_def := replace(v_def, v_cola,
$r$  -- mig NNN (#1592 H6): cada bloque se deshace con la configuración con la que se
  -- cerró, no con la de hoy. La fila de promo_ajustes que cierra bloques anota de qué
  -- barra es, sus unidades y su stock por bloque, y cuántos siguen cerrados
  -- (bloques_vivos). Bajar la barra por debajo de 0 abre los de esta barra del último
  -- al primero, y el fardo vuelve al contenedor del que salió. Lo que queda se vuelve
  -- a cerrar con la configuración de hoy: la barra sigue en [0, N). Antes, con un
  -- factor 6 → 4 de por medio, deshacer un bloque de 6 como de 4 devolvía un fardo de
  -- más (H6: el contenedor en 51, PROMO-A en rojo). Los movimientos se juntan por
  -- contenedor: en el de hoy, abrir uno y cerrar otro mueve sólo la diferencia.
  v_usos_raw := v_resto_actual + p_delta;
  v_movs     := '[]'::jsonb;
  v_abiertos := 0;
  IF v_usos_raw < 0 THEN
    v_falta := -v_usos_raw;
    -- Sin lock propio: estas filas sólo las escriben esta función y la
    -- renormalización, con la promo bloqueada.
    FOR t IN
      SELECT id, producto_id, usos_por_bloque, stock_por_bloque, bloques_vivos
        FROM promo_ajustes
       WHERE promocion_id = p_promocion_id
         AND sucursal_id = p_sucursal_id
         AND barra_regalo_id = p_producto_regalo_id
         AND bloques_vivos > 0
       ORDER BY id DESC
    LOOP
      EXIT WHEN v_falta <= 0;
      v_k := LEAST(t.bloques_vivos, CEIL(v_falta / t.usos_por_bloque)::INT);
      UPDATE promo_ajustes SET bloques_vivos = bloques_vivos - v_k WHERE id = t.id;
      v_falta    := v_falta - v_k * t.usos_por_bloque;
      v_abiertos := v_abiertos + v_k;
      -- Un contenedor borrado (la FK pone producto_id en NULL) no recibe nada.
      IF t.producto_id IS NOT NULL THEN
        v_movs := v_movs || jsonb_build_array(jsonb_build_object(
          'c', t.producto_id, 's', v_k * t.stock_por_bloque, 'u', -(v_k * t.usos_por_bloque), 'cierra', 0));
      END IF;
    END LOOP;
    -- Bloques sin anotar (los que la migración no pudo atribuir a una barra): la
    -- cuenta de hoy, con el tope de lo que la promo le sacó a ese contenedor y no
    -- tiene dueño en la pila. Nunca devuelve un fardo que no se descontó.
    IF v_falta > 0 THEN
      v_k := CEIL(v_falta / v_n)::INT;
      IF v_contenedor IS NOT NULL THEN
        SELECT COALESCE(SUM(unidades_ajustadas), 0) INTO v_neto
          FROM promo_ajustes
         WHERE promocion_id = p_promocion_id AND sucursal_id = p_sucursal_id
           AND producto_id = v_contenedor;
        SELECT COALESCE(SUM(bloques_vivos * stock_por_bloque), 0) INTO v_vivos
          FROM promo_ajustes
         WHERE promocion_id = p_promocion_id AND sucursal_id = p_sucursal_id
           AND producto_id = v_contenedor AND bloques_vivos > 0;
        -- Lo que este llamado ya abrió en ese contenedor salió de los vivos y todavía
        -- no del neto (su fila va abajo).
        SELECT COALESCE(SUM((x->>'s')::INT), 0) INTO v_ya
          FROM jsonb_array_elements(v_movs) x
         WHERE (x->>'c')::BIGINT = v_contenedor;
        v_k := LEAST(v_k, GREATEST(FLOOR((v_neto - v_vivos - v_ya)::NUMERIC / v_spb)::INT, 0));
        IF v_k > 0 THEN
          v_movs := v_movs || jsonb_build_array(jsonb_build_object(
            'c', v_contenedor, 's', v_k * v_spb, 'u', -(v_k * v_n), 'cierra', 0));
        END IF;
      END IF;
      v_falta    := v_falta - v_k * v_n;
      v_abiertos := v_abiertos + v_k;
    END IF;
    -- Lo que el tope no cubrió se pierde en la barra (queda en 0).
    v_usos_raw := GREATEST(-v_falta, 0);
  END IF;

  -- Lo que queda cierra con la configuración de hoy.
  v_cierra := FLOOR(v_usos_raw / v_n)::INT;
  -- Una baja de la barra (salvedad, cancelación, edición a la baja) no falla por falta
  -- de stock: el recierre se limita a lo que el contenedor de hoy tiene, más lo que este
  -- mismo movimiento le devuelve, y el resto queda en la barra aunque pase de N. La
  -- próxima venta lo cierra. Sólo el alta (una suba) rechaza por stock insuficiente.
  IF p_delta < 0 AND v_cierra > 0 AND v_contenedor IS NOT NULL THEN
    SELECT COALESCE(SUM((x->>'s')::INT), 0) INTO v_ya
      FROM jsonb_array_elements(v_movs) x
     WHERE (x->>'c')::BIGINT = v_contenedor;
    SELECT stock INTO v_stock_anterior
      FROM productos
     WHERE id = v_contenedor AND sucursal_id = p_sucursal_id
     FOR UPDATE;
    v_cierra := LEAST(v_cierra,
                      GREATEST(FLOOR((COALESCE(v_stock_anterior, 0) + v_ya)::NUMERIC / v_spb)::INT, 0));
  END IF;
  v_usos_final := v_usos_raw - (v_cierra * v_n);
  IF v_cierra > 0 AND v_contenedor IS NOT NULL THEN
    v_movs := v_movs || jsonb_build_array(jsonb_build_object(
      'c', v_contenedor, 's', -(v_cierra * v_spb), 'u', v_cierra * v_n, 'cierra', v_cierra));
  END IF;

  IF v_es_default THEN
    UPDATE promociones
       SET usos_pendientes = GREATEST(v_usos_final, 0)::INT
     WHERE id = p_promocion_id AND sucursal_id = p_sucursal_id;
  ELSE
    UPDATE promo_acumuladores
       SET usos_pendientes = v_usos_final, updated_at = NOW()
     WHERE id = v_acc_id;
  END IF;

  -- Un movimiento por contenedor, por id (el orden de los productos de la venta).
  FOR m IN
    SELECT (x->>'c')::BIGINT AS c, SUM((x->>'s')::INT)::INT AS s,
           SUM((x->>'u')::INT)::INT AS u, SUM((x->>'cierra')::INT)::INT AS cierra
      FROM jsonb_array_elements(v_movs) x
     GROUP BY 1
     ORDER BY 1
  LOOP
    v_stock_delta := m.s;
    v_merma_id    := NULL;
    v_foto        := NULL;
    v_lotes       := NULL;
    v_volver      := '[]'::jsonb;
    CONTINUE WHEN v_stock_delta = 0 AND m.cierra = 0;

    IF v_stock_delta <> 0 THEN
      SELECT stock, nombre INTO v_stock_anterior, v_cont_nombre
        FROM productos
       WHERE id = m.c AND sucursal_id = p_sucursal_id
       FOR UPDATE;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Auto-ajuste: producto destino no encontrado (promo %)', p_promocion_id;
      END IF;
      -- El alta y la edicion ya rechazaban esto con este mismo mensaje. Ahora vale
      -- para todos los caminos: un bloque no deja el contenedor en negativo.
      IF v_stock_delta < 0 AND COALESCE(v_stock_anterior, 0) < -v_stock_delta THEN
        RAISE EXCEPTION 'Auto-ajuste: stock insuficiente en % (disponible: %, requerido: %)',
          v_cont_nombre, COALESCE(v_stock_anterior, 0), -v_stock_delta;
      END IF;
      v_stock_nuevo := COALESCE(v_stock_anterior, 0) + v_stock_delta;

      v_org_prev      := current_setting('app.stock_origen', true);
      v_ref_tipo_prev := current_setting('app.stock_ref_tipo', true);
      v_ref_id_prev   := current_setting('app.stock_ref_id', true);
      v_user_prev     := current_setting('app.stock_user_id', true);
      v_item_prev     := current_setting('app.stock_pedido_item_id', true);

      -- #1558 (STK-19): el fardo vuelve a donde salió. La bajada come la bolsa
      -- primero (no mira el origen), así que una subida con una etiqueta de la
      -- lista blanca de trg_lotes_sincronizar mandaba al primer lote con hueco lo
      -- que había salido de la bolsa: el lote crecía en cada edición del pedido.
      -- Ahora la bajada anota de dónde salió (la foto de los lotes, como un
      -- envío) y la subida entra a la bolsa ('auto_ajuste_promo_a_su_lote', fuera
      -- de la lista blanca) y, más abajo, le devuelve a cada lote lo suyo.
      -- mig 269: el llamador puede pedir otro origen para la SUBIDA (cancelar
      -- por falta de stock: el fardo vuelve y se merma enseguida). Entonces queda
      -- en la bolsa, que es de donde lo come la merma.
      v_origen_subida := NULLIF(current_setting('app.contenedor_origen', true), '');
      IF v_stock_delta < 0 AND EXISTS (
           SELECT 1 FROM producto_lotes
            WHERE producto_id = m.c AND sucursal_id = p_sucursal_id) THEN
        v_foto := public._mov_lotes_foto(m.c, p_sucursal_id);
      END IF;

      PERFORM set_config('app.stock_origen',
        CASE WHEN v_stock_delta > 0
             THEN COALESCE(v_origen_subida, 'auto_ajuste_promo_a_su_lote')
             ELSE 'auto_ajuste_promo' END, true);
      PERFORM set_config('app.stock_ref_tipo', 'promocion', true);
      PERFORM set_config('app.stock_ref_id', p_promocion_id::TEXT, true);
      PERFORM set_config('app.stock_user_id', COALESCE(p_usuario_id::TEXT, ''), true);
      -- El contenedor no es ninguna línea: sin el GUC de la línea, la bajada no
      -- le escribe huella a una del mismo producto que viniera colgada del
      -- llamador (el fardo volvería dos veces, por la huella y por el registro).
      PERFORM set_config('app.stock_pedido_item_id', '', true);

      UPDATE productos SET stock = v_stock_nuevo, updated_at = NOW()
       WHERE id = m.c AND sucursal_id = p_sucursal_id;

      IF v_foto IS NOT NULL THEN
        -- Lo que salió de cada lote, FEFO; lo que falta para el bloque salió de
        -- la bolsa y va primero, que es como lo come la bajada.
        SELECT COALESCE(SUM(x.cantidad), 0)::INT,
               COALESCE(jsonb_agg(jsonb_build_object('lote_id', x.lote_id, 'cantidad', x.cantidad)
                                  ORDER BY x.fecha_vencimiento, x.lote_id), '[]'::jsonb)
          INTO v_de_lotes, v_lotes
          FROM jsonb_to_recordset(public._mov_lotes_diff(m.c, p_sucursal_id, v_foto, -1))
               AS x(lote_id BIGINT, fecha_vencimiento DATE, cantidad INT);
        IF -v_stock_delta > v_de_lotes THEN
          v_lotes := jsonb_build_array(jsonb_build_object('lote_id', NULL, 'cantidad', -v_stock_delta - v_de_lotes))
                     || v_lotes;
        END IF;
      ELSIF v_stock_delta > 0 THEN
        -- Los fardos de esta promo en este contenedor, del último al primero, y
        -- cada uno del final al principio (lo último que comió la bajada). Es la
        -- bolsa de lotes del contenedor, aparte de la pila de bloques: la vuelta
        -- neta de este movimiento sale de ahí.
        v_pendiente := v_stock_delta;
        FOR t IN
          SELECT id, lotes_pendientes
            FROM promo_ajustes
           WHERE promocion_id = p_promocion_id
             AND producto_id = m.c
             AND sucursal_id = p_sucursal_id
             AND lotes_pendientes IS NOT NULL
           ORDER BY id DESC
        LOOP
          EXIT WHEN v_pendiente <= 0;
          v_queda := t.lotes_pendientes;
          FOR e IN
            SELECT a.ord, (a.x->>'lote_id')::BIGINT AS lote_id, (a.x->>'cantidad')::INT AS cantidad
              FROM jsonb_array_elements(t.lotes_pendientes) WITH ORDINALITY AS a(x, ord)
             ORDER BY a.ord DESC
          LOOP
            EXIT WHEN v_pendiente <= 0;
            v_toma := LEAST(v_pendiente, e.cantidad);
            CONTINUE WHEN v_toma <= 0;
            IF e.lote_id IS NOT NULL AND v_origen_subida IS NULL THEN
              v_volver := v_volver || jsonb_build_array(jsonb_build_object('lote_id', e.lote_id, 'cantidad', v_toma));
            END IF;
            v_queda := jsonb_set(v_queda, ARRAY[(e.ord - 1)::TEXT, 'cantidad'], to_jsonb(e.cantidad - v_toma));
            v_pendiente := v_pendiente - v_toma;
          END LOOP;
          UPDATE promo_ajustes
             SET lotes_pendientes = (SELECT jsonb_agg(a.x ORDER BY a.ord)
                                       FROM jsonb_array_elements(v_queda) WITH ORDINALITY AS a(x, ord)
                                      WHERE (a.x->>'cantidad')::INT > 0)
           WHERE id = t.id;
        END LOOP;
        -- Lo que salió de un lote vuelve a ese lote, hasta su hueco; lo que no
        -- entra, y lo que salió de la bolsa, queda en la bolsa.
        IF jsonb_array_length(v_volver) > 0 THEN
          PERFORM public._mov_lotes_devolver(p_sucursal_id, v_volver);
        END IF;
      END IF;

      PERFORM set_config('app.stock_origen',   COALESCE(v_org_prev, ''), true);
      PERFORM set_config('app.stock_ref_tipo', COALESCE(v_ref_tipo_prev, ''), true);
      PERFORM set_config('app.stock_ref_id',   COALESCE(v_ref_id_prev, ''), true);
      PERFORM set_config('app.stock_user_id',  COALESCE(v_user_prev, ''), true);
      PERFORM set_config('app.stock_pedido_item_id', COALESCE(v_item_prev, ''), true);

      v_obs_merma := CASE WHEN COALESCE(p_motivo, '') LIKE '%Promo:%' THEN p_motivo
                          ELSE COALESCE(p_motivo, 'Auto-ajuste') || ' (Promo: ' || v_promo.nombre || ')' END;

      INSERT INTO mermas_stock (
        producto_id, cantidad, motivo, observaciones,
        stock_anterior, stock_nuevo, usuario_id, sucursal_id
      ) VALUES (
        m.c,
        -v_stock_delta,
        CASE WHEN v_stock_delta < 0 THEN 'promociones' ELSE 'promociones_reversion' END,
        v_obs_merma, COALESCE(v_stock_anterior, 0), v_stock_nuevo, p_usuario_id, p_sucursal_id
      ) RETURNING id INTO v_merma_id;
    END IF;

    -- promo_ajustes.observaciones conserva el motivo tal cual: la mig 212 lee
    -- sus prefijos ('Auto-ajuste%', 'Cancelacion pedido #%', ...). La fila de un
    -- bloque que se abre y se cierra en el mismo contenedor no mueve stock ni
    -- tiene merma: no empieza con 'Auto-ajuste' (BONIF-C pide la merma a ésas).
    v_obs_fila := COALESCE(p_motivo, 'Auto-ajuste');
    IF v_merma_id IS NULL THEN
      v_obs_fila := 'Bloque rehecho sin mover stock: ' || v_obs_fila;
    END IF;
    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id,
      lotes_pendientes,
      barra_regalo_id, usos_por_bloque, stock_por_bloque, bloques_vivos
    ) VALUES (
      p_promocion_id, m.u, -v_stock_delta,
      m.c, v_merma_id, p_usuario_id, v_obs_fila, p_sucursal_id,
      v_lotes,
      p_producto_regalo_id,
      CASE WHEN m.cierra > 0 THEN v_n END,
      CASE WHEN m.cierra > 0 THEN v_spb END,
      CASE WHEN m.cierra > 0 THEN m.cierra END
    );
  END LOOP;

  v_stock_delta := (SELECT COALESCE(SUM((x->>'s')::INT), 0) FROM jsonb_array_elements(v_movs) x);

  RETURN jsonb_build_object(
    'aplicado', true,
    'barra', CASE WHEN v_es_default THEN 'default' ELSE 'sabor' END,
    'acumulador_id', v_acc_id,
    'contenedor', v_contenedor,
    'usos_pendientes', v_usos_final,
    'bloques_delta', v_cierra - v_abiertos,
    'unidades_stock', -v_stock_delta,
    'unidades_por_bloque', v_n
  );
$r$);

  EXECUTE v_def;
END
$parche_acumulador$;

-- =========================================================================
-- 1c · renormalizar_bloques_por_cambio_factor: el bloque que cierra anota su
--      barra y su configuración
-- =========================================================================
DO $parche_renormalizar$
DECLARE
  v_def text := pg_get_functiondef('public.renormalizar_bloques_por_cambio_factor()'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$    SELECT NULL::bigint AS acc_id,
           GREATEST(COALESCE(v_promo.usos_pendientes, 0), 0)::numeric AS resto,
           v_promo.ajuste_producto_id AS contenedor
    UNION ALL
    SELECT a.id, GREATEST(COALESCE(a.usos_pendientes, 0), 0), a.ajuste_producto_id
$a$,
$r$    -- mig NNN (#1592 H6): y el regalo de cada barra, que es lo que anota el bloque.
    SELECT NULL::bigint AS acc_id,
           GREATEST(COALESCE(v_promo.usos_pendientes, 0), 0)::numeric AS resto,
           v_promo.ajuste_producto_id AS contenedor,
           v_promo.producto_regalo_id AS regalo
    UNION ALL
    SELECT a.id, GREATEST(COALESCE(a.usos_pendientes, 0), 0), a.ajuste_producto_id, a.producto_regalo_id
$r$, 'renormalizar (las barras)');

  v_def := pg_temp.parche(v_def,
$a$    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id,
      lotes_pendientes
    ) VALUES (
      NEW.id, v_bloques * v_n, v_unidades,
      v_barra.contenedor, v_merma_id, v_usuario, v_obs, NEW.sucursal_id,
      v_lotes
    );
$a$,
$r$    -- mig NNN (#1592 H6): el bloque anota su barra y su configuración (la nueva),
    -- para que deshacerlo devuelva lo que sacó.
    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas,
      producto_id, merma_id, usuario_id, observaciones, sucursal_id,
      lotes_pendientes,
      barra_regalo_id, usos_por_bloque, stock_por_bloque, bloques_vivos
    ) VALUES (
      NEW.id, v_bloques * v_n, v_unidades,
      v_barra.contenedor, v_merma_id, v_usuario, v_obs, NEW.sucursal_id,
      v_lotes,
      v_barra.regalo, v_n, v_spb, v_bloques
    );
$r$, 'renormalizar (la fila del bloque)');

  EXECUTE v_def;
END
$parche_renormalizar$;

-- =========================================================================
-- 1d · _contenedores_de_promos: también los contenedores de los bloques vivos
-- =========================================================================
DO $parche_contenedores$
DECLARE
  v_def text := pg_get_functiondef('public._contenedores_de_promos(bigint[],bigint)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$   WHERE a.promocion_id = ANY (p_promos) AND a.sucursal_id = p_sucursal_id AND a.ajuste_producto_id IS NOT NULL;
$a$,
$r$   WHERE a.promocion_id = ANY (p_promos) AND a.sucursal_id = p_sucursal_id AND a.ajuste_producto_id IS NOT NULL
  -- mig NNN (#1592 H6): un bloque vivo vuelve al contenedor del que salió, que puede
  -- no ser el de hoy: se toma con los demás, antes que la promo.
  UNION
  SELECT pa.producto_id FROM promo_ajustes pa
   WHERE pa.promocion_id = ANY (p_promos) AND pa.sucursal_id = p_sucursal_id
     AND pa.bloques_vivos > 0 AND pa.producto_id IS NOT NULL;
$r$, '_contenedores_de_promos');

  EXECUTE v_def;
END
$parche_contenedores$;

-- =========================================================================
-- 1e · los bloques que las barras ya tienen cerrados (datos)
-- =========================================================================
-- Por cada barra de una promo de fracción con ajuste automático (la del regalo
-- de la promo y las de promo_acumuladores) cuyo contenedor no comparte con otra
-- barra de la misma promo: lo que la promo le sacó a ese contenedor y no devolvió
-- (la cuenta de PROMO-A) son sus bloques cerrados. Se anotan con la
-- configuración de hoy, el día de la anotación, que es con la que hoy se
-- deshacen (la premisa de datos de arriba garantiza que nunca hubo otra). La fila
-- no mueve stock ni unidades: sólo anota la pila. Dos barras con el mismo
-- contenedor no se pueden separar (la premisa ya lo descarta): seguirían con la
-- cuenta de hoy y su tope.
DO $bloques_previos$
DECLARE
  r       record;
  v_u     bigint;
  v_bulto int;
  v_n     int;
  v_spb   int;
  v_k     int;
  v_filas int := 0;
  v_bloq  bigint := 0;
BEGIN
  FOR r IN
    WITH barras AS (
      SELECT p.id AS promo, p.sucursal_id AS suc, p.producto_regalo_id AS regalo,
             p.ajuste_producto_id AS cont, p.unidades_por_bloque AS upb, p.stock_por_bloque AS spb
        FROM promociones p
       WHERE p.producto_regalo_id IS NOT NULL AND p.ajuste_producto_id IS NOT NULL
         AND p.regalo_mueve_stock IS FALSE AND COALESCE(p.ajuste_automatico, false)
         AND COALESCE(p.unidades_por_bloque, 0) > 0 AND COALESCE(p.stock_por_bloque, 0) > 0
      UNION ALL
      SELECT p.id, p.sucursal_id, a.producto_regalo_id, a.ajuste_producto_id,
             p.unidades_por_bloque, p.stock_por_bloque
        FROM promo_acumuladores a
        JOIN promociones p ON p.id = a.promocion_id AND p.sucursal_id = a.sucursal_id
       WHERE a.ajuste_producto_id IS NOT NULL
         AND a.producto_regalo_id IS DISTINCT FROM p.producto_regalo_id
         AND p.regalo_mueve_stock IS FALSE AND COALESCE(p.ajuste_automatico, false)
         AND COALESCE(p.unidades_por_bloque, 0) > 0 AND COALESCE(p.stock_por_bloque, 0) > 0
    )
    SELECT b.*, count(*) OVER (PARTITION BY b.promo, b.suc, b.cont) AS comparten
      FROM barras b
     ORDER BY b.promo, b.regalo
  LOOP
    CONTINUE WHEN r.comparten > 1;
    SELECT COALESCE(SUM(unidades_ajustadas), 0) INTO v_u
      FROM promo_ajustes
     WHERE promocion_id = r.promo AND sucursal_id = r.suc AND producto_id = r.cont;
    CONTINUE WHEN v_u <= 0;
    -- El N y el stock por bloque de esa barra hoy (mig 295, como aplicar_uso_promo_acumulador).
    SELECT unidades_por_bulto INTO v_bulto
      FROM productos WHERE id = r.cont AND sucursal_id = r.suc;
    IF v_bulto IS NOT NULL THEN
      v_n := v_bulto; v_spb := 1;
    ELSE
      v_n := r.upb; v_spb := r.spb;
    END IF;
    v_k := FLOOR(v_u::numeric / v_spb)::int;
    CONTINUE WHEN v_k <= 0;
    INSERT INTO promo_ajustes (
      promocion_id, usos_ajustados, unidades_ajustadas, producto_id, merma_id, usuario_id,
      observaciones, sucursal_id, barra_regalo_id, usos_por_bloque, stock_por_bloque, bloques_vivos
    ) VALUES (
      r.promo, 0, 0, r.cont, NULL, NULL,
      'Mig NNN: bloques que la barra ya tenía cerrados, anotados con la configuración de la promo el día de la anotación', r.suc,
      r.regalo, v_n, v_spb, v_k
    );
    v_filas := v_filas + 1;
    v_bloq  := v_bloq + v_k;
  END LOOP;
  RAISE NOTICE 'mig NNN · bloques previos anotados: % barra(s), % bloque(s)', v_filas, v_bloq;
END
$bloques_previos$;

-- =========================================================================
-- 2 · 1583-a · el corte guardado
-- =========================================================================
-- El corte que una línea de regalo tendría con otra cantidad: la cuenta de
-- sellar_corte_regalo_item para un UPDATE (lo guardado más lo que cambió la
-- cantidad medida en cortes), y sin corte guardado, el deducido.
CREATE FUNCTION public._regalo_corte_tras_cantidad(p_corte integer, p_eslabones jsonb, p_cadena uuid,
                                                   p_antes numeric, p_despues numeric)
RETURNS numeric
LANGUAGE sql
IMMUTABLE
SET search_path TO 'public'
AS $function$
  SELECT CASE
           WHEN p_corte IS NULL THEN public.regalo_usos_de_linea(p_eslabones, p_cadena, p_despues)::numeric
           WHEN p_despues IS NOT DISTINCT FROM p_antes THEN p_corte::numeric
           ELSE GREATEST(0, p_corte
                            + public.regalo_usos_de_linea(p_eslabones, p_cadena, p_despues)
                            - public.regalo_usos_de_linea(p_eslabones, p_cadena, p_antes))::numeric
         END;
$function$;

REVOKE ALL ON FUNCTION public._regalo_corte_tras_cantidad(integer, jsonb, uuid, numeric, numeric) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._regalo_corte_tras_cantidad(integer, jsonb, uuid, numeric, numeric) TO service_role;

-- _regalo_recorte devuelve también el corte que le queda a cada línea, y las
-- líneas cuyo corte baja aunque la cantidad no cambie. Cambia lo que devuelve:
-- se rehace (la llaman registrar_salvedad y las dos simulaciones, por nombre).
DROP FUNCTION public._regalo_recorte(bigint, bigint, bigint, numeric, jsonb);

CREATE FUNCTION public._regalo_recorte(p_pedido_id bigint, p_promocion_id bigint, p_sucursal_id bigint, p_exceso numeric, p_cantidades jsonb DEFAULT NULL::jsonb)
 RETURNS TABLE(pedido_item_id bigint, producto_id bigint, cantidad integer, cantidad_final integer, corte_final integer)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'public'
AS $function$
DECLARE
  v_eslabones jsonb := public.regalo_eslabones(p_pedido_id, p_promocion_id, p_sucursal_id);
  v_resto     numeric := COALESCE(p_exceso, 0);
  v_cant      integer;
  v_corte     numeric;
  v_saca      numeric;
  v_final     numeric;
  r           record;
BEGIN
  FOR r IN
    SELECT pi.id, pi.producto_id, pi.cantidad, pi.regalo_cadena_id, pi.regalo_corte
      FROM pedido_items pi
     WHERE pi.pedido_id = p_pedido_id AND pi.sucursal_id = p_sucursal_id
       AND COALESCE(pi.es_bonificacion, false) AND pi.promocion_id = p_promocion_id
     ORDER BY pi.id DESC
  LOOP
    EXIT WHEN v_resto <= 0;
    v_cant := COALESCE((p_cantidades->>(r.id::text))::integer, r.cantidad);
    CONTINUE WHEN v_cant <= 0;

    -- 1583-a (#1583): el corte guardado (#1556), con lo que le cambia una salvedad
    -- del mismo lote sobre la línea; sin él, el deducido de la cantidad. Con un cambio
    -- por valor que achica y una edición a más, el deducido no es el corte.
    v_corte := public._regalo_corte_tras_cantidad(r.regalo_corte, v_eslabones, r.regalo_cadena_id,
                                                  r.cantidad, v_cant);
    v_saca  := LEAST(v_corte, v_resto);
    v_resto := v_resto - v_saca;

    IF v_saca >= v_corte THEN
      v_final := 0;
    ELSE
      SELECT x.cantidad INTO v_final
        FROM public.regalo_sustitucion_resuelta(
               p_pedido_id, p_promocion_id,
               COALESCE(public.regalo_raiz_de_eslabones(v_eslabones, r.producto_id, r.regalo_cadena_id),
                        r.producto_id),
               p_sucursal_id, v_corte - v_saca, r.regalo_cadena_id) x;
      -- El redondeo de la cadena nunca sube la línea.
      v_final := LEAST(v_final, v_cant);
    END IF;

    -- También la línea que queda igual pero pierde corte: el recorte se lo escribe.
    IF v_final < v_cant OR v_saca > 0 THEN
      pedido_item_id := r.id;
      producto_id    := r.producto_id;
      cantidad       := v_cant;
      cantidad_final := v_final::integer;
      corte_final    := CASE WHEN v_final = 0 THEN 0 ELSE (v_corte - v_saca)::integer END;
      RETURN NEXT;
    END IF;
  END LOOP;
END;
$function$;

REVOKE ALL ON FUNCTION public._regalo_recorte(bigint, bigint, bigint, numeric, jsonb) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public._regalo_recorte(bigint, bigint, bigint, numeric, jsonb) TO service_role;

-- =========================================================================
-- 2b, 3 y 4 · registrar_salvedad
-- =========================================================================
DO $parche_salvedad$
DECLARE
  v_def text := pg_get_functiondef('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$  v_caja_cerrada          TEXT;
BEGIN
$a$,
$r$  v_caja_cerrada          TEXT;
  -- 1583-a (#1583): la marca del corte escrito a mano, del llamador.
  v_corte_guc             TEXT;
BEGIN
$r$, 'registrar_salvedad (declaraciones)');

  -- 1564-b2: la sucursal antes que la NC.
  v_def := pg_temp.parche(v_def,
$a$  -- mig 276 (#833): sobre el pedido de una NC vigente no hay salvedad.
$a$,
$r$  -- 1564-b2 (#1564): el pedido tiene que ser de la sucursal activa antes de leer nada
  -- de él. El admin y el encargado no pasaban por la pertenencia de arriba, y la NC
  -- vigente de un pedido de otra sucursal se le contaba a quien no lo puede ver.
  IF NOT EXISTS (SELECT 1 FROM pedidos WHERE id = p_pedido_id AND sucursal_id = v_sucursal) THEN
    RETURN jsonb_build_object('success', false, 'error', 'Pedido no encontrado', 'codigo', 'pedido_no_encontrado');
  END IF;

  -- mig 276 (#833): sobre el pedido de una NC vigente no hay salvedad.
$r$, 'registrar_salvedad (1564-b2)');

  -- 1595-b5: en camino o entregado.
  v_def := pg_temp.parche(v_def,
$a$  -- #1327: un dia con la caja cerrada no cambia: ni el total, ni el stock. Va
$a$,
$r$  -- 1595-b5 (#1595, decisión del dueño D23): una salvedad se registra sólo sobre un
  -- pedido en reparto (asignado, "En camino") o entregado. Uno pendiente o en
  -- preparación todavía no salió: lo que no va se saca editándolo. Va después del
  -- reintento idempotente y del lock del pedido, como la baja.
  IF EXISTS (SELECT 1 FROM pedidos
              WHERE id = p_pedido_id
                AND sucursal_id = v_sucursal
                AND estado NOT IN ('asignado', 'entregado')) THEN
    RETURN jsonb_build_object(
      'success', false,
      'error', 'El pedido #' || p_pedido_id || ' todavía no salió a reparto: una salvedad se registra sólo sobre un pedido en camino o entregado. Si hay que sacar algo, editá el pedido.',
      'codigo', 'pedido_sin_salir'
    );
  END IF;

  -- #1327: un dia con la caja cerrada no cambia: ni el total, ni el stock. Va
$r$, 'registrar_salvedad (1595-b5)');

  -- 1583-a: el exceso se mide con el corte guardado.
  v_def := pg_temp.parche(v_def,
$a$           SUM(public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad))::INT AS total_bonif,
$a$,
$r$           -- 1583-a (#1583): el corte guardado en la línea (#1556), que es lo que cuenta
           -- el cupo; sin él, el deducido. Con un cambio por valor que achica (R×10 →
           -- W×1) y una edición a más, W×1 se deshace en 10 y el corte guardado es 14.
           SUM(COALESCE(pi.regalo_corte, public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad)))::INT AS total_bonif,
$r$, 'registrar_salvedad (1583-a, el exceso)');

  v_def := pg_temp.parche(v_def,
$a$               , r.cantidad_final
$a$,
$r$               , r.cantidad_final, r.corte_final
$r$, 'registrar_salvedad (1583-a, el corte de cada línea)');

  v_def := pg_temp.parche(v_def,
$a$        IF COALESCE(v_regalo_mueve_stock, FALSE) THEN
$a$,
$r$        -- 1583-a: una línea que sólo pierde corte no devuelve nada.
        IF COALESCE(v_regalo_mueve_stock, FALSE) AND v_diff > 0 THEN
$r$, 'registrar_salvedad (1583-a, el stock)');

  v_def := pg_temp.parche(v_def,
$a$        IF public._regalo_barra_vale(p_pedido_id, v_bonif.promocion_id, v_sucursal) THEN
          PERFORM public.aplicar_uso_promo_acumulador(
            v_bonif.promocion_id, v_bonif.producto_id, -v_diff,
$a$,
$r$        IF v_diff > 0 AND public._regalo_barra_vale(p_pedido_id, v_bonif.promocion_id, v_sucursal) THEN
          PERFORM public.aplicar_uso_promo_acumulador(
            v_bonif.promocion_id, v_bonif.producto_id, -v_diff,
$r$, 'registrar_salvedad (1583-a, la barra)');

  v_def := pg_temp.parche(v_def,
$a$          UPDATE pedido_items
             SET cantidad = v_bonif.cantidad - v_diff,
                 subtotal = (v_bonif.cantidad - v_diff) * COALESCE(precio_unitario, 0)
           WHERE id = v_bonif.id;
$a$,
$r$          -- 1583-a: el corte que le queda lo escribe el recorte (sellar_corte_regalo_item
          -- lo respeta con la marca), aunque la cantidad no cambie. La marca es por
          -- transacción: se guarda y se restaura.
          v_corte_guc := current_setting('app.regalo_corte_manual', true);
          PERFORM set_config('app.regalo_corte_manual', '1', true);
          UPDATE pedido_items
             SET cantidad = v_bonif.cantidad - v_diff,
                 subtotal = (v_bonif.cantidad - v_diff) * COALESCE(precio_unitario, 0),
                 regalo_corte = v_bonif.corte_final
           WHERE id = v_bonif.id;
          PERFORM set_config('app.regalo_corte_manual', COALESCE(v_corte_guc, ''), true);
$r$, 'registrar_salvedad (1583-a, la línea)');

  EXECUTE v_def;
END
$parche_salvedad$;

-- =========================================================================
-- 2c · las dos simulaciones miden con el corte guardado
-- =========================================================================
DO $parche_simular_una$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedad_promo_impacto(bigint,bigint,integer)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$           SUM(public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad))::INT AS corte
$a$,
$r$           -- 1583-a (#1583): el corte guardado, como registrar_salvedad.
           SUM(COALESCE(pi.regalo_corte, public.regalo_usos_de_linea(
                 CASE WHEN pi.regalo_cadena_id IS NOT NULL
                      THEN public.regalo_eslabones(p_pedido_id, pi.promocion_id, v_sucursal) END,
                 pi.regalo_cadena_id, pi.cantidad)))::INT AS corte
$r$, 'simular_salvedad_promo_impacto (el corte)');

  EXECUTE v_def;
END
$parche_simular_una$;

DO $parche_simular_lote$
DECLARE
  v_def text := pg_get_functiondef('public.simular_salvedades_promo_impacto(bigint,jsonb)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$           pi.descripcion_regalo, pi.regalo_cadena_id,
$a$,
$r$           pi.descripcion_regalo, pi.regalo_cadena_id, pi.regalo_corte,
$r$, 'simular_salvedades_promo_impacto (el corte de cada línea)');

  v_def := pg_temp.parche(v_def,
$a$                    THEN public.regalo_usos_de_linea(
                           CASE WHEN b.regalo_cadena_id IS NOT NULL
                                THEN public.regalo_eslabones(p_pedido_id, b.promocion_id, current_sucursal_id()) END,
                           b.regalo_cadena_id, b.cantidad_post)
$a$,
$r$                    -- 1583-a (#1583): el corte guardado, con lo que le cambia la
                    -- salvedad del lote sobre el regalo mismo (como registrar_salvedad).
                    THEN public._regalo_corte_tras_cantidad(
                           b.regalo_corte,
                           CASE WHEN b.regalo_cadena_id IS NOT NULL
                                THEN public.regalo_eslabones(p_pedido_id, b.promocion_id, current_sucursal_id()) END,
                           b.regalo_cadena_id, b.cantidad, b.cantidad_post)
$r$, 'simular_salvedades_promo_impacto (el corte del lote)');

  EXECUTE v_def;
END
$parche_simular_lote$;

-- =========================================================================
-- 2d · anular_salvedad: un recorte que sólo baja el corte también es un
--      recorte (H2 de la revisión). Por ancla y sin md5: otra tarjeta de la
--      ola parcha esta función antes; la premisa de arriba comprueba el ancla.
-- =========================================================================
DO $parche_anular$
DECLARE
  v_def text := pg_get_functiondef('public.anular_salvedad(bigint,text)'::regprocedure);
BEGIN
  v_def := pg_temp.parche(v_def,
$a$                      AND (f.accion = 'DELETE'
                           OR (f.new_data->>'cantidad')::numeric < (f.old_data->>'cantidad')::numeric))
$a$,
$r$                      AND (f.accion = 'DELETE'
                           OR (f.new_data->>'cantidad')::numeric < (f.old_data->>'cantidad')::numeric
                           -- mig NNN (1583-a, H2 de la revisión): el recorte que sólo baja el
                           -- corte guardado (W×1 sigue W×1, corte 14 → 10) también es un recorte.
                           OR (f.new_data->>'regalo_corte')::numeric < (f.old_data->>'regalo_corte')::numeric))
$r$, 'anular_salvedad (el recorte del corte)');

  EXECUTE v_def;
END
$parche_anular$;

-- ---------------------------------------------------------------------------
-- Poscondición: los cuerpos, el definer y los EXECUTE quedaron como en el repo
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  r record;
  x record;
BEGIN
  FOR r IN SELECT * FROM (VALUES
    ('public.aplicar_uso_promo_acumulador(bigint,bigint,numeric,bigint,bigint,uuid,text)', 'b55ff7a09db621f71f6e29d55bfea808', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.renormalizar_bloques_por_cambio_factor()', '2b282b2a6629e3b067f4de39157889e9', true,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._contenedores_de_promos(bigint[],bigint)', 'a9febeec0cb96eef6751cb16cc9da6bf', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.registrar_salvedad(bigint,bigint,integer,character varying,text,text,boolean,uuid)', 'a8232d05d0fc8f1124b7974f490db222', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public._regalo_recorte(bigint,bigint,bigint,numeric,jsonb)', '9a75cd56b30e348f7963c40cccdb8b48', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public._regalo_corte_tras_cantidad(integer,jsonb,uuid,numeric,numeric)', '0d1b375e3a1f8d0ebdb7285441666c77', false,
     '{postgres=X/postgres,service_role=X/postgres}'),
    ('public.simular_salvedad_promo_impacto(bigint,bigint,integer)', '39f54fafd82f4c47d051ca9b782e3daa', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}'),
    ('public.simular_salvedades_promo_impacto(bigint,jsonb)', '1d8b373b43595f8bc1ef4541827b4ca4', true,
     '{postgres=X/postgres,authenticated=X/postgres,service_role=X/postgres}')
  ) AS t(f, h, def, acl) LOOP
    SELECT md5(prosrc) AS h, proacl::text AS a, prosecdef AS def INTO x
      FROM pg_proc WHERE oid = r.f::regprocedure;
    IF x.h IS DISTINCT FROM r.h OR x.a IS DISTINCT FROM r.acl OR x.def IS DISTINCT FROM r.def THEN
      RAISE EXCEPTION 'mig NNN · % no quedó como en el repo (md5 %, acl %, definer %)', r.f, x.h, x.a, x.def;
    END IF;
  END LOOP;
  IF EXISTS (SELECT 1 FROM promo_ajustes
              GROUP BY promocion_id, sucursal_id, producto_id
             HAVING SUM(COALESCE(bloques_vivos, 0) * COALESCE(stock_por_bloque, 0))
                    > GREATEST(SUM(COALESCE(unidades_ajustadas, 0)), 0)) THEN
    RAISE EXCEPTION 'mig NNN · la pila anotó más bloques vivos que los fardos que la promo sacó';
  END IF;
  -- anular_salvedad va sin md5 (la parcha otra tarjeta de la ola): la línea nueva, una vez.
  IF (SELECT (length(prosrc) - length(replace(prosrc,
        $l$OR (f.new_data->>'regalo_corte')::numeric < (f.old_data->>'regalo_corte')::numeric))$l$, '')))
        / length($l$OR (f.new_data->>'regalo_corte')::numeric < (f.old_data->>'regalo_corte')::numeric))$l$)
        FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) <> 1
     OR NOT (SELECT prosecdef FROM pg_proc WHERE oid = 'public.anular_salvedad(bigint,text)'::regprocedure) THEN
    RAISE EXCEPTION 'mig NNN · anular_salvedad no quedó con la detección del recorte del corte';
  END IF;
END
$post$;

COMMIT;
