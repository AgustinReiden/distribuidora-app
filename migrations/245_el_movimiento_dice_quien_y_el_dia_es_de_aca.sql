-- ============================================================================
-- 245 · El movimiento dice quién, y el día es de acá
-- ============================================================================
-- Seis correcciones mecánicas sobre cuerpos VIVOS de prod
-- (`pg_get_functiondef`), verificadas una por una antes de escribir el archivo.
-- Ninguna cambia un criterio de negocio: las definiciones canónicas --la venta
-- del vendedor (241), el criterio de merma y la cascada de costo (238), la
-- lista blanca de orígenes del trigger de lotes (223/229)-- quedan intactas.
--
-- Cierra #613, #633 y #639.
--
-- ---------------------------------------------------------------------------
-- 1 · registrar_ingreso_sucursal no etiquetaba el movimiento (#613)
--
--     Era la última función de `public` que sube `productos.stock` sin declarar
--     `app.stock_origen`: sus movimientos caían en `stock_historico` como
--     `origen='auto'`, sin usuario y sin referencia, y engordaban STK-D.
--     `registrar_compra_completa`, su gemela, se corrigió en la 240; acá se
--     copia ese patrón tal cual: las cuatro GUCs apenas se conoce
--     `v_transferencia_id` y antes del bucle, porque `set_config(..., true)` es
--     por TRANSACCIÓN, no por sentencia, y la función no tenía ningún
--     `set_config` propio que pisar.
--
--     `'ingreso_sucursal'` NO entra a la lista blanca de
--     `sincronizar_lotes_stock`, por la misma razón que `'compra'` y
--     `'control_stock'` en la 240: lo que sube es mercadería NUEVA y va a la
--     bolsa "sin vencimiento". El camino de BAJADA del trigger no mira el
--     origen, así que nada cambia para las salidas. Ni una unidad de
--     `producto_lotes` se mueve: cambia quién figura en el ledger.
--
--     Con eso, la última excepción de `auditoria_funciones_stock_sin_origen()`
--     (la que dejó la 229 y adelgazó la 240) deja de tener sentido y SE SACA.
--     Medido contra prod antes de escribir esto: con la lista de excepciones
--     vacía, la única función que aparecía era `registrar_ingreso_sucursal`.
--     O sea que después de este parche el check da 0 y el `NOT IN` ya no tapa
--     nada.
--
-- ---------------------------------------------------------------------------
-- 2 · Cuatro checks de auditoria_integridad() acotados a canal='app' (#633)
--
--     La 241 alineó once funciones a la venta canónica --`estado='entregado'`,
--     `canal <> 'cambio'`, por `pedidos.fecha`, atribuida a `usuario_id`--
--     pero `auditoria_integridad()` quedó del otro lado: VENTA-E, COSTO-B,
--     COMIS-01 y COMIS-05 miraban `canal='app'`, así que un pedido tomado por
--     el bot los esquivaba. El canal se filtra EN NEGATIVO, como manda la 241:
--     el dominio es `('app','cambio','bot')` y lo que se excluye es la comanda
--     de un canje.
--
--     COMIS-05 también se amplía, y la verificación que pedía el issue está
--     hecha: se leyó el cuerpo vivo de `crear_pedido_completo_bot` y SÍ escribe
--     `creado_por` --su `INSERT INTO pedidos` nombra la columna y le pone
--     `p_perfil_id`, el mismo valor que a `usuario_id`--. O sea que el centinela
--     de atribución vale igual para el camino del bot; quedaba afuera por el
--     `canal='app'`, no porque el bot dejara la columna en NULL. El hallazgo
--     queda escrito al lado del check, no sólo acá.
--
--     NO hace falta ningún centinela tipo CC-B: los cuatro se midieron contra
--     prod con el filtro nuevo antes de aplicar, y ninguno destapa cohorte
--     legacy.
--
--       · VENTA-E   · canal='app' → 0 · canal<>'cambio' → 0
--       · COSTO-B   · canal='app' → 1 · canal<>'cambio' → 1  (el mismo producto)
--       · COMIS-01  · canal='app' → 2 · canal<>'cambio' → 2  (pedidos 872 y 904,
--                     los dos `canal='app'` de marzo 2026, o sea que ya estaban
--                     adentro)
--       · COMIS-05  · canal='app' → 0 · canal<>'cambio' → 0
--
--     Hoy no hay ningún pedido `canal='bot'` en prod, así que ampliar no mueve
--     un solo número: mueve lo que el gate va a ver el día que lo haya, que es
--     de lo que se trata. `overall_ok` sigue en true.
--
--     Las descripciones se corrigen junto con los predicados: una descripción
--     que sigue diciendo "app" cuando el check ya no filtra por app es la
--     próxima confusión.
--
-- ---------------------------------------------------------------------------
-- 3 · obtener_resumen_rendiciones tapaba el día que sólo tuvo gastos (#639)
--
--     `fechas_activas` es el esqueleto de la grilla, y se armaba con la unión
--     de `pagos_agg` y `entregas_agg`. `gastos_agg` estaba calculado y
--     LEFT-JOINeado más abajo, pero no aportaba filas: un transportista que un
--     día sólo cargó gastos --no cobró nada y no entregó nada-- no aparecía, y
--     su rendición de ese día quedaba invisible para el control. Se suma el
--     tercer brazo al UNION.
--
--     `rendicion_gastos` está VACÍA en prod hoy (0 filas), así que no hay fecha
--     real con la que probarlo: el ensayo del final lo verifica con una fila
--     insertada y borrada dentro de la misma transacción.
--
-- ---------------------------------------------------------------------------
-- 4 · reporte_vencimientos cortaba el día en UTC (#639)
--
--     Dos `CURRENT_DATE`: la columna `dias_restantes` y el filtro de horizonte.
--     `CURRENT_DATE` es la fecha del servidor en UTC, así que entre las 21 y
--     las 00 hora argentina un lote figuraba con un día MENOS de vida del que
--     tiene, y el horizonte corría con él. Se reemplazan por la fecha de acá,
--     el mismo idioma que ya usan las funciones que corrigieron la 230 y la
--     231.
--
-- ---------------------------------------------------------------------------
-- 5 · Las dos funciones de auditoría del bot comparaban DATE contra timestamptz (#639)
--
--     `bot_admin_audit_log` y `bot_admin_audit_summary` filtraban
--     `al.created_at >= p_desde AND al.created_at < p_hasta + interval '1 day'`.
--     `created_at` es `timestamptz` y `p_desde`/`p_hasta` son `DATE`: Postgres
--     promueve la fecha a medianoche UTC, así que el rango cortaba el día tres
--     horas tarde --los eventos de 21:00 a 00:00 hora argentina caían en el día
--     siguiente--. Se pasan al mismo corte por día argentino que usan
--     `mermas_valorizadas` (238) y las siete que corrigió la 231:
--     `(created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN
--     p_desde AND p_hasta`.
--
--     Las dos funciones quedan SEPARADAS a propósito: una devuelve el detalle y
--     la otra los agregados, tienen firmas distintas y llamadores distintos.
--     Unificarlas sería un refactor de paso.
--
--     `v_errores_recientes` del summary NO se toca: no filtra por el rango del
--     reporte sino por `now() - interval '24 hours'`, que es una ventana móvil
--     sobre timestamptz y ya está bien.
--
-- ---------------------------------------------------------------------------
-- 6 · Diez funciones con search_path mutable (#639)
--
--     Los advisors de seguridad de Supabase las marcan una por una. Son las
--     tres nuevas de la 238 (`costo_valuacion`, `costo_valuacion_origen`,
--     `merma_clasificacion`), cuatro funciones puras de costo y venta, la de
--     bloques, y dos funciones de trigger `set_updated_at`. Ninguna es
--     `SECURITY DEFINER`, así que el riesgo es menor, pero un `search_path`
--     mutable en una función que resuelve nombres sin calificar es exactamente
--     el agujero que el advisor describe. `ALTER FUNCTION ... SET search_path =
--     public` a las diez: no cambia el cuerpo, no cambia los permisos, no
--     cambia lo que devuelven.
--
--     Las dos de trigger se quedan sin `EXECUTE` para nadie, que es lo que
--     corresponde: las invoca el executor como parte del DML, no el caller.
--
-- ---------------------------------------------------------------------------
-- QUÉ NO SE TOCA
--
--   · Ningún reporte ni criterio: la venta canónica (241), el criterio de merma
--     y la cascada de costo (238) quedan exactamente como están.
--   · La lista blanca de `sincronizar_lotes_stock` no recibe un solo origen
--     nuevo.
--   · Las dos funciones de auditoría del bot siguen siendo dos.
--   · El `CURRENT_DATE` de VENTA-E: ese check pregunta "¿hay una venta con
--     fecha futura?" sobre una columna `date`, y cambiarle el corte es tocarle
--     el criterio a un invariante. Este archivo sólo le cambia el canal.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · El andamio: cirugía por ancla sobre el cuerpo vivo.
--     Mismo helper que la 229, la 236, la 240, la 241 y la 242. Falla si el
--     ancla no aparece exactamente una vez: si otra sesión cambió el cuerpo,
--     esta migración no entra a medias.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._mig245_ancla(
  p_funcion regprocedure,
  p_ancla   text,
  p_nuevo   text
) RETURNS void
LANGUAGE plpgsql
AS $fn$
DECLARE
  v_def   text;
  v_veces int;
BEGIN
  v_def := pg_get_functiondef(p_funcion);
  v_veces := (length(v_def) - length(replace(v_def, p_ancla, ''))) / length(p_ancla);
  IF v_veces <> 1 THEN
    RAISE EXCEPTION 'El ancla aparece % veces en % (se esperaba exactamente 1). El cuerpo vivo cambio: revisar a mano. Ancla: %',
      v_veces, p_funcion, left(p_ancla, 120);
  END IF;
  EXECUTE replace(v_def, p_ancla, p_nuevo);
END;
$fn$;

-- El ensayo del final afirma cosas sobre el TEXTO de los cuerpos parcheados
-- ("ya no queda un CURRENT_DATE", "ya no queda un canal='app'"), y los
-- comentarios que dejan los parches de arriba CITAN justamente lo que se fue.
-- Mirar el cuerpo con los comentarios adentro da un falso rojo, asi que se los
-- saca primero: bloque /* */ y linea --.
CREATE OR REPLACE FUNCTION public._mig245_sin_comentarios(p_def text)
RETURNS text
LANGUAGE sql
IMMUTABLE
AS $fn$
  SELECT regexp_replace(
           regexp_replace(p_def, '/\*.*?\*/', '', 'gs'),
           '--[^' || chr(10) || ']*', '', 'g');
$fn$;

-- ---------------------------------------------------------------------------
-- 1 · registrar_ingreso_sucursal: el ingreso dice de qué transferencia viene.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'registrar_ingreso_sucursal';

  PERFORM public._mig245_ancla(v_fn,
$ancla$  RETURNING id INTO v_transferencia_id;
  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$ancla$,
$nuevo$  RETURNING id INTO v_transferencia_id;

  /* mig 245 (#613) · el ledger de stock sabe de que ingreso vino la mercaderia.
     Era el ultimo camino de stock sin etiquetar: las entradas por ingreso de
     sucursal caian como origen='auto', sin referencia y sin usuario, y las
     contaba STK-D. Mismo patron que le puso la 240 a registrar_compra_completa.
     'ingreso_sucursal' NO va a la lista blanca de sincronizar_lotes_stock: lo
     que sube es mercaderia NUEVA y va a la bolsa "sin vencimiento". */
  PERFORM set_config('app.stock_origen',   'ingreso_sucursal', true);
  PERFORM set_config('app.stock_ref_tipo', 'ingreso_sucursal', true);
  PERFORM set_config('app.stock_ref_id',   v_transferencia_id::TEXT, true);
  PERFORM set_config('app.stock_user_id',  COALESCE(COALESCE(p_usuario_id, auth.uid())::TEXT, ''), true);

  FOR v_item IN SELECT * FROM jsonb_array_elements(p_items) LOOP
$nuevo$);
END
$patch$;

-- Toda funcion de public nace con EXECUTE para PUBLIC y Supabase se lo concede
-- ademas a anon: las dos mitades se revocan juntas. El CREATE OR REPLACE de
-- arriba no reabre los grants, pero se reafirman para que el gate no dependa de
-- eso.
REVOKE ALL ON FUNCTION public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb) TO authenticated;

-- ---------------------------------------------------------------------------
-- 1.b · STK-F se queda sin excepciones.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auditoria_funciones_stock_sin_origen()
RETURNS bigint
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $fn$
  SELECT count(*)
    FROM pg_proc f
   WHERE f.pronamespace = 'public'::regnamespace
     AND f.prokind = 'f'
     AND pg_get_functiondef(f.oid) ~* 'UPDATE\s+productos\s+(AS\s+)?(\w+\s+)?SET[^;]*\ystock\s*=\s*(\w+\.)?stock\s*\+'
     AND pg_get_functiondef(f.oid) NOT LIKE '%app.stock_origen%';
$fn$;

COMMENT ON FUNCTION public.auditoria_funciones_stock_sin_origen() IS
  'Cuenta funciones de public que suben productos.stock sin declarar '
  'app.stock_origen. Alimenta el check STK-F. mig 229; la 240 le saco la '
  'excepcion de registrar_compra_completa y la 245 la de '
  'registrar_ingreso_sucursal: ahora no tiene ninguna.';

REVOKE ALL ON FUNCTION public.auditoria_funciones_stock_sin_origen() FROM PUBLIC, anon;

-- ---------------------------------------------------------------------------
-- 2 · auditoria_integridad(): cuatro checks miran el universo de la venta.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- 2.a) VENTA-E · fecha nula o futura.
  PERFORM public._mig245_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('VENTA-E','high','venta entregada/app sin fecha nula ni futura',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal='app' AND (fecha IS NULL OR fecha>CURRENT_DATE))),$ancla$,
$nuevo$    -- mig 245 (#633) · canal EN NEGATIVO, como la 241: el universo de la venta
    -- es todo canal menos la comanda de canje. Medido antes de ampliar: 0 y 0.
    ('VENTA-E','high','venta entregada (cualquier canal de venta) sin fecha nula ni futura',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND (fecha IS NULL OR fecha>CURRENT_DATE))),$nuevo$);

  -- 2.b) COSTO-B · costo nulo o cero en items no bonificados de entregados.
  PERFORM public._mig245_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$        WHERE p.estado='entregado' AND p.canal='app' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0))),$ancla$,
$nuevo$        WHERE p.estado='entregado' AND p.canal<>'cambio' AND NOT pi.es_bonificacion AND (prod.costo_sin_iva IS NULL OR prod.costo_sin_iva=0))),$nuevo$);

  -- 2.c) COMIS-01 · venta sin vendedor valido.
  PERFORM public._mig245_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COMIS-01','medium','venta entregada/app sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal='app' AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),$ancla$,
$nuevo$    -- mig 245 (#633) · el mas importante de los cuatro: desde la 241 la venta
    -- del bot suma al gerencial y comisiona, asi que un pedido 'bot' con
    -- usuario_id fuera de perfiles alimentaria los reportes sin que el check lo
    -- vea. Medido antes de ampliar: 2 y 2 (pedidos 872 y 904, los dos del
    -- canal de la app, de marzo 2026, o sea que ya estaban adentro).
    ('COMIS-01','medium','venta entregada sin vendedor (usuario_id en perfiles)',
      (SELECT count(*) FROM pedidos WHERE estado='entregado' AND canal<>'cambio' AND (usuario_id IS NULL OR usuario_id NOT IN (SELECT id FROM perfiles)))),$nuevo$);

  -- 2.d) COMIS-05 · centinela de creado_por.
  PERFORM public._mig245_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('COMIS-05','high','pedidos app de últimas 2h con creado_por poblado (centinela de atribución)',
      (SELECT count(*) FROM pedidos WHERE created_at >= now()-interval '2 hours' AND canal='app' AND creado_por IS NULL)),$ancla$,
$nuevo$    -- mig 245 (#633) · el issue pedia verificar que escribe
    -- crear_pedido_completo_bot en creado_por antes de tocar este check. Se leyo
    -- el cuerpo VIVO: su INSERT INTO pedidos nombra la columna creado_por y le
    -- pone p_perfil_id --el mismo valor que a usuario_id--, asi que el bot puebla
    -- la atribucion igual que la app y el centinela vale para los dos caminos.
    -- Quedaba afuera por el filtro de canal, no porque el bot dejara la columna
    -- en NULL. Medido antes de ampliar: 0 y 0.
    ('COMIS-05','high','pedidos de venta de últimas 2h con creado_por poblado (centinela de atribución)',
      (SELECT count(*) FROM pedidos WHERE created_at >= now()-interval '2 hours' AND canal<>'cambio' AND creado_por IS NULL)),$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 3 · obtener_resumen_rendiciones: el dia que solo tuvo gastos tambien es un dia.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'obtener_resumen_rendiciones';

  PERFORM public._mig245_ancla(v_fn,
$ancla$  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
  )$ancla$,
$nuevo$  /* mig 245 (#639) · fechas_activas es el esqueleto de la grilla. gastos_agg ya
     estaba calculado y LEFT-JOINeado abajo, pero no aportaba filas: un
     transportista que un dia solo cargo gastos --sin cobrar ni entregar-- no
     aparecia, y su rendicion de ese dia era invisible para el control. */
  fechas_activas AS (
    SELECT t_id, f FROM pagos_agg
    UNION
    SELECT t_id, f FROM entregas_agg
    UNION
    SELECT t_id, f FROM gastos_agg
  )$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 4 · reporte_vencimientos: el vencimiento se cuenta contra el dia de aca.
-- ---------------------------------------------------------------------------
DO $patch$
DECLARE v_fn regprocedure;
BEGIN
  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_vencimientos';

  -- 4.a) La columna dias_restantes.
  PERFORM public._mig245_ancla(v_fn,
$ancla$         (l.fecha_vencimiento - CURRENT_DATE)::integer,$ancla$,
$nuevo$         -- mig 245 (#639) · CURRENT_DATE es el dia del servidor en UTC: entre
         -- las 21 y las 00 hora argentina un lote figuraba con un dia MENOS de
         -- vida del que tiene. Misma fecha de aca que usan la 230 y la 231.
         (l.fecha_vencimiento - (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date)::integer,$nuevo$);

  SELECT p.oid::regprocedure INTO v_fn FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace AND p.proname = 'reporte_vencimientos';

  -- 4.b) El filtro de horizonte, que corria con la columna.
  PERFORM public._mig245_ancla(v_fn,
$ancla$     AND (l.fecha_vencimiento - CURRENT_DATE) <= COALESCE(p_dias_horizonte, 3650)$ancla$,
$nuevo$     AND (l.fecha_vencimiento - (now() AT TIME ZONE 'America/Argentina/Buenos_Aires')::date) <= COALESCE(p_dias_horizonte, 3650)$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 5 · Las dos funciones de auditoria del bot cortan el dia en hora argentina.
--
--     Cinco rangos en total: uno en el detalle y cuatro en el resumen. Cada
--     ancla lleva la linea que lo hace unico (el `;`, el GROUP BY, el filtro de
--     perfil, el filtro de tool), porque el helper exige exactamente una
--     aparicion.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  -- 5.a) bot_admin_audit_log · el unico rango del detalle.
  PERFORM public._mig245_ancla('public.bot_admin_audit_log(date, date, text, uuid, integer)'::regprocedure,
$ancla$    WHERE al.created_at >= p_desde
      AND al.created_at <  p_hasta + interval '1 day'$ancla$,
$nuevo$    -- mig 245 (#639) · created_at es timestamptz y p_desde/p_hasta son DATE:
    -- Postgres los promovia a medianoche UTC y el rango cortaba el dia tres
    -- horas tarde. Mismo corte por dia argentino que mermas_valorizadas (238).
    WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta$nuevo$);

  -- 5.b) bot_admin_audit_summary · total de eventos.
  PERFORM public._mig245_ancla('public.bot_admin_audit_summary(date, date)'::regprocedure,
$ancla$    FROM bot_audit_log
   WHERE created_at >= p_desde
     AND created_at <  p_hasta + interval '1 day';$ancla$,
$nuevo$    FROM bot_audit_log
   -- mig 245 (#639) · corte por dia argentino, como en bot_admin_audit_log.
   WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta;$nuevo$);

  -- 5.c) bot_admin_audit_summary · por tipo.
  PERFORM public._mig245_ancla('public.bot_admin_audit_summary(date, date)'::regprocedure,
$ancla$       WHERE created_at >= p_desde
         AND created_at <  p_hasta + interval '1 day'
       GROUP BY tipo$ancla$,
$nuevo$       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
       GROUP BY tipo$nuevo$);

  -- 5.d) bot_admin_audit_summary · por perfil.
  PERFORM public._mig245_ancla('public.bot_admin_audit_summary(date, date)'::regprocedure,
$ancla$      WHERE al.created_at >= p_desde
        AND al.created_at <  p_hasta + interval '1 day'
        AND al.perfil_id IS NOT NULL$ancla$,
$nuevo$      WHERE (al.created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
        AND al.perfil_id IS NOT NULL$nuevo$);

  -- 5.e) bot_admin_audit_summary · top de tools.
  --      v_errores_recientes NO se toca: no filtra por el rango del reporte sino
  --      por now() - interval '24 hours', una ventana movil sobre timestamptz
  --      que ya esta bien.
  PERFORM public._mig245_ancla('public.bot_admin_audit_summary(date, date)'::regprocedure,
$ancla$       WHERE created_at >= p_desde
         AND created_at <  p_hasta + interval '1 day'
         AND tool_name IS NOT NULL$ancla$,
$nuevo$       WHERE (created_at AT TIME ZONE 'America/Argentina/Buenos_Aires')::date BETWEEN p_desde AND p_hasta
         AND tool_name IS NOT NULL$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 6 · Las diez funciones con search_path mutable que marcan los advisors.
--
--     ALTER FUNCTION no toca el cuerpo, ni los permisos, ni lo que devuelven.
-- ---------------------------------------------------------------------------
ALTER FUNCTION public.costo_valuacion(numeric, numeric, numeric, numeric, numeric) SET search_path = public;
ALTER FUNCTION public.costo_valuacion_origen(numeric, numeric, numeric, numeric)   SET search_path = public;
ALTER FUNCTION public.merma_clasificacion(text)                                    SET search_path = public;
ALTER FUNCTION public.costo_financiero_unitario(numeric, numeric, numeric, text)   SET search_path = public;
ALTER FUNCTION public.costo_real_unitario(numeric, numeric, text, numeric)         SET search_path = public;
ALTER FUNCTION public.factor_bonificacion(integer, boolean, integer)               SET search_path = public;
ALTER FUNCTION public.calcular_desglose_venta(numeric, numeric, numeric, text)     SET search_path = public;
ALTER FUNCTION public.bloques_a_cerrar(numeric, integer)                           SET search_path = public;
ALTER FUNCTION public.marcas_set_updated_at()                                      SET search_path = public;
ALTER FUNCTION public.metas_preventista_set_updated_at()                           SET search_path = public;

-- ---------------------------------------------------------------------------
-- 7 · El ensayo. Si algo de esto no da, la migracion entera se cae.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_def       text;
  v_admin     uuid;
  v_transp    uuid;
  v_suc       bigint;
  v_fecha     date;
  v_gasto_id  bigint;
  v_filas     bigint;
  v_gastos    numeric;
  v_n         int;
BEGIN
  -- 7.1 · registrar_ingreso_sucursal tiene las cuatro GUCs.
  v_def := pg_get_functiondef('public.registrar_ingreso_sucursal(bigint, date, text, numeric, uuid, jsonb)'::regprocedure);
  IF v_def NOT LIKE '%app.stock_origen%'
     OR v_def NOT LIKE '%app.stock_ref_tipo%'
     OR v_def NOT LIKE '%app.stock_ref_id%'
     OR v_def NOT LIKE '%app.stock_user_id%'
     OR v_def NOT LIKE '%''ingreso_sucursal''%' THEN
    RAISE EXCEPTION 'mig245 · registrar_ingreso_sucursal quedo sin las cuatro GUCs';
  END IF;

  -- 7.2 · STK-F: sin excepciones y en cero.
  v_def := pg_get_functiondef('public.auditoria_funciones_stock_sin_origen()'::regprocedure);
  IF v_def LIKE '%registrar_ingreso_sucursal%' THEN
    RAISE EXCEPTION 'mig245 · auditoria_funciones_stock_sin_origen todavia tiene la excepcion';
  END IF;
  IF public.auditoria_funciones_stock_sin_origen() <> 0 THEN
    RAISE EXCEPTION 'mig245 · quedan % funciones que suben stock sin etiquetar',
      public.auditoria_funciones_stock_sin_origen();
  END IF;

  -- 7.3 · No queda un solo canal='app' en auditoria_integridad, y el gate sigue
  --       verde. (posicion_fiscal, que filtra por app A PROPOSITO, es otra
  --       funcion: no la toca este archivo ni la mira este ensayo.)
  v_def := public._mig245_sin_comentarios(
             pg_get_functiondef('public.auditoria_integridad()'::regprocedure));
  IF v_def LIKE '%canal=''app''%' THEN
    RAISE EXCEPTION 'mig245 · auditoria_integridad todavia tiene un check en canal=app';
  END IF;
  v_n := (length(v_def) - length(replace(v_def, 'canal<>''cambio''', ''))) / length('canal<>''cambio''');
  IF v_n < 4 THEN
    RAISE EXCEPTION 'mig245 · se esperaban al menos 4 checks con canal<>cambio, hay %', v_n;
  END IF;
  IF (public.auditoria_integridad()->>'overall_ok')::boolean IS NOT TRUE THEN
    RAISE EXCEPTION 'mig245 · auditoria_integridad quedo en rojo: %',
      public.auditoria_integridad()->'checks';
  END IF;

  -- 7.4 · Ni CURRENT_DATE ni comparacion DATE-vs-timestamptz.
  IF public._mig245_sin_comentarios(
       pg_get_functiondef('public.reporte_vencimientos(integer)'::regprocedure)) LIKE '%CURRENT_DATE%' THEN
    RAISE EXCEPTION 'mig245 · reporte_vencimientos todavia tiene CURRENT_DATE';
  END IF;
  IF public._mig245_sin_comentarios(
       pg_get_functiondef('public.bot_admin_audit_log(date, date, text, uuid, integer)'::regprocedure)) LIKE '%p_hasta + interval%'
     OR public._mig245_sin_comentarios(
       pg_get_functiondef('public.bot_admin_audit_summary(date, date)'::regprocedure)) LIKE '%p_hasta + interval%' THEN
    RAISE EXCEPTION 'mig245 · las funciones del bot todavia comparan DATE contra timestamptz';
  END IF;

  -- 7.5 · Las diez con search_path fijo.
  SELECT count(*) INTO v_n FROM pg_proc p
   WHERE p.pronamespace = 'public'::regnamespace
     AND p.proname IN ('costo_valuacion','costo_valuacion_origen','merma_clasificacion',
                       'costo_financiero_unitario','costo_real_unitario','factor_bonificacion',
                       'calcular_desglose_venta','bloques_a_cerrar','marcas_set_updated_at',
                       'metas_preventista_set_updated_at')
     AND (p.proconfig IS NULL OR NOT (p.proconfig && ARRAY['search_path=public']));
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig245 · quedan % funciones sin search_path fijo', v_n;
  END IF;

  -- 7.6 · El dia que solo tuvo gastos aparece en la grilla.
  --       rendicion_gastos esta VACIA en prod, asi que no hay fecha real que
  --       mirar: se inserta una fila en una fecha sin cobros ni entregas, se
  --       llama a la funcion impersonando a un admin de esa sucursal, y se
  --       borra. Si algo falla, el EXCEPTION tira toda la transaccion abajo y la
  --       fila no queda igual.
  SELECT us.usuario_id, us.sucursal_id INTO v_admin, v_suc
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'admin' AND us.es_default
   ORDER BY us.sucursal_id LIMIT 1;

  SELECT us.usuario_id INTO v_transp
    FROM usuario_sucursales us JOIN perfiles p ON p.id = us.usuario_id
   WHERE p.rol = 'transportista' AND us.sucursal_id = v_suc LIMIT 1;

  IF v_admin IS NULL OR v_transp IS NULL THEN
    RAISE EXCEPTION 'mig245 · no hay admin o transportista para el ensayo de rendiciones';
  END IF;

  v_fecha := DATE '2020-01-02';   -- bien lejos de cualquier cobro o entrega real

  INSERT INTO rendicion_gastos (fecha, transportista_id, sucursal_id, descripcion, monto, creado_por)
  VALUES (v_fecha, v_transp, v_suc, 'mig245 · ensayo', 123.45, v_admin)
  RETURNING id INTO v_gasto_id;

  PERFORM set_config('request.jwt.claim.sub', v_admin::text, true);

  SELECT count(*), COALESCE(max(r.total_gastos), 0) INTO v_filas, v_gastos
    FROM public.obtener_resumen_rendiciones(v_fecha, v_fecha, v_transp) r;

  PERFORM set_config('request.jwt.claim.sub', '', true);
  DELETE FROM rendicion_gastos WHERE id = v_gasto_id;

  IF v_filas <> 1 OR v_gastos <> 123.45 THEN
    RAISE EXCEPTION 'mig245 · el dia con solo gastos no aparece: filas=% total_gastos=%', v_filas, v_gastos;
  END IF;

  RAISE NOTICE 'mig245 · ensayo OK · el dia con solo gastos devuelve % fila con total_gastos=%', v_filas, v_gastos;
END
$ensayo$;

DROP FUNCTION public._mig245_ancla(regprocedure, text, text);
DROP FUNCTION public._mig245_sin_comentarios(text);

COMMIT;
