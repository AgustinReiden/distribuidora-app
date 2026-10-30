-- ============================================================================
-- NNN · El bot: el resumen que no se pierde, números que cierran y el apagado
--       que dura (#1309, #1310, #1311; plan #1308, tarjeta 1)
-- ============================================================================
-- El número se elige al aplicar, contra el ledger de prod y origin/main
-- (trampa 3 de CLAUDE.md). Aplicar desde el contenido LF.
--
-- QUÉ ES ESTO
-- -----------
-- #1309 · el resumen diario.
--   · BOT-1. `bot_digest_destinatarios` pedía `hora_local = p_hora` exacta, y el
--     cron horario de GitHub llega tarde o se saltea: si no corría entre las 7 y
--     las 7:59 de Argentina, ese día no salía y no se recuperaba (14 días de 41,
--     nada desde el 24/10). Ahora `bot_digest_pendientes` devuelve a quien le
--     toca desde su hora EN ADELANTE y todavía no lo recibió ese día: la primera
--     corrida a partir de la hora lo manda. Lo mismo el aviso semanal de
--     atrasados, en el lugar (`bot_aviso_atrasados_destinatarios`).
--   · BOT-2. El resumen salía de `bot_usuarios.sucursal_id`, que es lo que
--     escribe `/sucursal`: el admin que miraba Taco Pozo recibía Taco Pozo sin
--     que lo dijera, y nunca Tucumán. Ahora hay un resumen por cada sucursal
--     ACTIVA asignada al perfil (`usuario_sucursales`), con su nombre, y NULL ya
--     no es "la Red": sin sucursal asignada no hay resumen. La definición de a
--     quién le toca vive en una sola función, `bot_digest_suscripciones()`, que
--     usan las pendientes y el gate.
--   · BOT-10 (doble envío). La marca se toma ANTES de mandar
--     (`bot_digest_reservar`, INSERT … ON CONFLICT … RETURNING): de dos corridas
--     a la vez, una sola manda. Un 'error' se puede reintentar; un 'enviando'
--     colgado no (preferimos perder un resumen, que el gate ve, a mandarlo dos
--     veces). `bot_digests_enviados` pasa a tener una fila por
--     (perfil, fecha, sucursal).
--   · El gate: `auditoria_bot()` + scripts/check-bot.mjs en integridad.yml. Falla
--     si a alguien con el resumen activo le tocaba uno entre hace 30 y hace 2
--     horas y no le llegó, o si está suscripto y no tiene ninguna sucursal activa
--     (antes recibía la Red; ahora no recibiría nada sin que nadie se entere).
--     Un usuario que bloqueó el bot (403 de Telegram) queda 'skipped': no se
--     reintenta cada hora ni deja el gate rojo para siempre.
-- #1310 · números que no cierran.
--   · BOT-3. El stock crítico de `bot_metricas_admin_dia` contaba productos dados
--     de baja (36 de 82 en la sucursal 1), y "Tomados" contaba las comandas de
--     canje.
--   · BOT-4. El ranking por producto y el top de `bot_ventas_periodo` sumaban las
--     unidades de regalo como vendidas (el 6,3% en 30 días). El top de productos
--     del resumen tenía el mismo problema y va con el mismo arreglo.
--   · BOT-7. `bot_recorrido_resumen` tomaba un recorrido cualquiera del día;
--     ahora el último, como `bot_mi_recorrido`.
--   · BOT-8. `obtener_resumen_cuenta_cliente_bot.total_compras` sumaba `total`,
--     con el envío y lo no entregado. Ahora es la venta de CLAUDE.md: entregado,
--     sin canjes, sin VB y sin envío (la ficha del bot usa la misma regla para
--     "lo propio"). `ultimo_pedido` queda para #1277.
-- #1311 · el apagado y el buscador.
--   · BOT-5 (decisión del dueño, 29/10). Apagar el bot desde el panel es
--     definitivo hasta que el admin lo vuelva a prender. La marca vive en una
--     tabla propia, `bot_apagados_por_admin`, una fila por PERFIL: es de la
--     persona, no del chat, así vincular otro Telegram tampoco la saltea. "No
--     vinculado" es no tener fila en `bot_usuarios`; "apagado por el usuario"
--     (/desvincular, o el chat viejo al vincular otro) es `activo = false` sin
--     marca, y el canje lo vuelve a prender como siempre. El trigger
--     `trg_bot_usuarios_respeta_apagado` no deja prender ningún chat de un perfil
--     marcado, venga de donde venga; el canje y el código lo rechazan con su
--     mensaje, y sólo `bot_admin_toggle_usuario` borra la marca. El canje
--     también rechaza un chat cuyo dueño actual está marcado, aunque el código
--     sea de otro perfil: si el chat se pasara a otro, el apagado quedaría sin
--     ninguna fila en el panel desde donde el admin pueda volver a prenderlo.
--     Apagar desde el panel apaga todos los chats de la persona (la marca es de
--     ella), no sólo el de la fila.
--   · BOT-6. `bot_buscar_cliente`: la rama de asignación deja pasar al encargado,
--     como la de reservado y como la ficha. Ya filtra por la sucursal.
--
-- QUÉ SE TOCA
-- -----------
-- Tablas: `bot_apagados_por_admin` (nueva, sólo de server), `bot_digests_enviados`
--   (sucursal_id en la PK, status 'enviando'), `bot_avisos_atrasados_enviados`
--   (status 'enviando'), `bot_pedidos_pendientes.cancelado_at` (para que el bot
--   no conteste "pedido ya creado" a uno que se canceló).
-- Nuevas, sólo de servidor (sin EXECUTE para PUBLIC, anon ni authenticated):
--   bot_digest_suscripciones, bot_digest_pendientes, bot_digest_reservar,
--   bot_digest_registrar, bot_aviso_atrasados_reservar, auditoria_bot, y la del
--   trigger, bot_usuarios_respeta_apagado.
-- Reemplazadas enteras (md5 verificado): bot_aviso_atrasados_destinatarios,
--   bot_admin_toggle_usuario.
-- Parcheadas por ancla sobre el cuerpo vivo (md5 verificado): bot_metricas_admin_dia,
--   bot_ranking_preventistas_por_producto, bot_ventas_periodo,
--   bot_recorrido_resumen, obtener_resumen_cuenta_cliente_bot, bot_buscar_cliente,
--   bot_admin_digests_enviados, canjear_codigo_vinculacion_bot,
--   generar_codigo_vinculacion_bot.
-- Se dropea `bot_digest_destinatarios(integer, integer)`: la reemplaza
--   `bot_digest_pendientes`. Ninguna otra cambia de firma ni de RETURNS: CREATE
--   OR REPLACE conserva dueño, SECURITY DEFINER, search_path y ACL (lo verifica
--   el paso 9).
--
-- ORDEN: PRIMERO EL DEPLOY, DESPUÉS ESTA MIGRACIÓN
-- ------------------------------------------------
-- Se aplica apenas `deploy-functions.yml` publica las edge functions del PR, no
-- antes. Al revés, la edge function vieja correría contra la PK nueva: su upsert
-- `onConflict: admin_perfil_id,fecha` falla, manda sin dejar marca, y el día del
-- deploy la nueva le manda a todos el mismo resumen otra vez.
-- En el orden correcto, entre el deploy y la migración la función nueva no
-- encuentra `bot_digest_pendientes`, contesta 500 (el workflow queda rojo) y no
-- manda nada; la primera corrida después de aplicar manda lo pendiente del día,
-- porque el resumen sale "desde su hora". Lo demás del bot en esa ventana: cancelar
-- un borrador de pedido contesta "no pude cancelar" (falta `cancelado_at`; el
-- borrador vence solo a los 10 minutos) y el resto anda como antes.
-- ============================================================================

BEGIN;

DO $lf$
BEGIN
  IF position(E'\r' in current_query()) > 0 THEN
    RAISE EXCEPTION 'mig NNN · el texto de la migración trae CRLF: aplicarla desde la versión LF (git show HEAD:migrations/<archivo>)';
  END IF;
END
$lf$;

-- ---------------------------------------------------------------------------
-- 0 · Premisas: nada cambió en prod desde que se leyeron los cuerpos (29/10,
--     después de la 413).
-- ---------------------------------------------------------------------------
DO $premisas$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.md5, md5(pg_get_functiondef(x.firma::regprocedure)) AS md5_vivo
      FROM (VALUES
        ('public.bot_metricas_admin_dia(date,bigint)',                                  '48ab565b8f69daf59e5aa7d00bf6ffa2'),
        ('public.bot_ranking_preventistas_por_producto(bigint[],date,date,bigint,integer)', '7314028d5745d4165d46245cb3778559'),
        ('public.bot_ventas_periodo(date,date,bigint,integer)',                         '2b2856564c9261d1a0b7c5364246743a'),
        ('public.bot_recorrido_resumen(uuid,bigint,date)',                              '4268aa7a69ed2e12a655cefd2487daf3'),
        ('public.obtener_resumen_cuenta_cliente_bot(integer)',                          '4fed640ef27145379d6dc6636ee0ca73'),
        ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',                    '0dc476ca61045ab93ab48be865f3c0bf'),
        ('public.bot_admin_digests_enviados(date,date)',                                'f11b887b89e2254c7021b194a913b060'),
        ('public.canjear_codigo_vinculacion_bot(text,bigint,text)',                     'c2c5ad2fe1a827095240f33eb2b453bf'),
        ('public.generar_codigo_vinculacion_bot()',                                     'dab83b04974952749c3d06c0be4bc723'),
        ('public.bot_aviso_atrasados_destinatarios(integer,integer)',                   '3b66e183f48a97683da7a8b7c2081d39'),
        ('public.bot_admin_toggle_usuario(bigint,boolean)',                             '96fadafdab266dd9b17c1286b0fcc1ee'),
        ('public.bot_digest_destinatarios(integer,integer)',                            '08d4825e6eb6fde1208b607495df8f8a')
      ) AS x(firma, md5)
  LOOP
    IF v_f.md5_vivo <> v_f.md5 THEN
      RAISE EXCEPTION 'mig NNN · % cambió en prod desde que se leyó (md5 %, esperado %): rehacer los parches sobre la definición vigente',
        v_f.firma, v_f.md5_vivo, v_f.md5;
    END IF;
  END LOOP;

  -- El backfill de la sucursal de los envíos viejos supone que cada fila tiene
  -- de dónde sacarla: el chat que la recibió o la sucursal default del perfil.
  IF EXISTS (
    SELECT 1 FROM bot_digests_enviados d
     WHERE NOT EXISTS (SELECT 1 FROM bot_usuarios bu
                        WHERE bu.telegram_user_id = d.telegram_user_id AND bu.sucursal_id IS NOT NULL)
       AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us WHERE us.usuario_id = d.admin_perfil_id)
  ) THEN
    RAISE EXCEPTION 'mig NNN · hay envíos del resumen sin sucursal de dónde sacarla: revisar el backfill del paso 2';
  END IF;

  -- El CHECK nuevo de status reemplaza al de siempre: si alguien le cambió el
  -- nombre, el DROP de abajo no lo encontraría y quedarían los dos.
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bot_digests_enviados_status_check')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bot_avisos_atrasados_enviados_status_check')
     OR NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'bot_digests_enviados_pkey') THEN
    RAISE EXCEPTION 'mig NNN · los constraints de los envíos del bot no se llaman como se esperaba';
  END IF;
END
$premisas$;

-- ---------------------------------------------------------------------------
-- 1 · BOT-5: la marca de "apagado por el admin"
-- ---------------------------------------------------------------------------
-- Una fila por perfil. La escribe y la borra sólo `bot_admin_toggle_usuario`.
-- Sólo de server: RLS sin policies y sin grants (como `pedido_promo_reglas`).
CREATE TABLE public.bot_apagados_por_admin (
  perfil_id        uuid PRIMARY KEY REFERENCES public.perfiles(id) ON DELETE CASCADE,
  apagado_at       timestamptz NOT NULL DEFAULT now(),
  apagado_por      uuid REFERENCES public.perfiles(id) ON DELETE SET NULL,
  -- El chat que el admin apagó (informativo: la marca vale para todos).
  telegram_user_id bigint
);

COMMENT ON TABLE public.bot_apagados_por_admin IS
  'Perfiles a los que un admin les apagó el bot desde el panel (#1311, decisión del dueño 29/10). Mientras haya fila, ningún chat del perfil se puede prender: ni el canje de un código ni /vincular desde otro Telegram (trg_bot_usuarios_respeta_apagado). Sólo bot_admin_toggle_usuario la escribe y la borra. Distinto de "no vinculado" (sin fila en bot_usuarios) y de "apagado por el usuario" (/desvincular: activo = false sin marca).';

ALTER TABLE public.bot_apagados_por_admin ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.bot_apagados_por_admin FROM PUBLIC, anon, authenticated;

-- Ningún chat de un perfil marcado se prende, venga de donde venga.
CREATE FUNCTION public.bot_usuarios_respeta_apagado()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF NEW.activo AND EXISTS (SELECT 1 FROM bot_apagados_por_admin a WHERE a.perfil_id = NEW.perfil_id) THEN
    RAISE EXCEPTION 'Un administrador le apagó el bot a este usuario: sólo un admin lo vuelve a prender, desde el panel del bot (#1311)'
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END;
$function$;

CREATE TRIGGER trg_bot_usuarios_respeta_apagado
  BEFORE INSERT OR UPDATE OF activo, perfil_id ON public.bot_usuarios
  FOR EACH ROW EXECUTE FUNCTION public.bot_usuarios_respeta_apagado();

-- Una función de trigger no necesita EXECUTE para nadie (CLAUDE.md, #1245).
REVOKE ALL ON FUNCTION public.bot_usuarios_respeta_apagado() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_usuarios_respeta_apagado() TO service_role;

-- El panel: apagar marca a la persona y apaga todos sus chats; prender borra la
-- marca y prende el chat elegido. El permiso es el de siempre (#1244).
CREATE OR REPLACE FUNCTION public.bot_admin_toggle_usuario(p_telegram_user_id bigint, p_activo boolean)
 RETURNS json
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
DECLARE
  v_rol      TEXT;
  v_perfil   UUID;
BEGIN
  SELECT rol INTO v_rol FROM perfiles WHERE id = auth.uid();
  IF v_rol IS DISTINCT FROM 'admin' THEN
    RAISE EXCEPTION 'Solo admin puede activar/desactivar usuarios del bot';
  END IF;

  -- #1244: como el activo del perfil, lo cambia un admin de todas las
  -- sucursales del usuario.
  SELECT bu.perfil_id INTO v_perfil
    FROM bot_usuarios bu
   WHERE bu.telegram_user_id = p_telegram_user_id
     AND admin_abarca_sucursales_de(bu.perfil_id)
   FOR UPDATE;

  IF NOT FOUND THEN
    IF EXISTS (SELECT 1 FROM bot_usuarios
                WHERE telegram_user_id = p_telegram_user_id
                  AND admin_comparte_sucursal_con(perfil_id)) THEN
      RAISE EXCEPTION 'Ese usuario también trabaja en sucursales que no son tuyas: su bot lo activa o lo desactiva un admin de todas ellas';
    END IF;
    RAISE EXCEPTION 'Usuario de bot no encontrado: %', p_telegram_user_id;
  END IF;

  IF p_activo THEN
    -- Prender (#1311): primero se borra la marca, que es lo que el trigger mira.
    DELETE FROM bot_apagados_por_admin WHERE perfil_id = v_perfil;
    UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = p_telegram_user_id;
  ELSE
    -- Apagar (#1311): es definitivo hasta que un admin lo prenda. La marca es de
    -- la persona, así que se apagan todos sus chats: si quedara uno prendido, la
    -- marca y el chat se contradirían.
    INSERT INTO bot_apagados_por_admin (perfil_id, apagado_at, apagado_por, telegram_user_id)
    VALUES (v_perfil, now(), auth.uid(), p_telegram_user_id)
    ON CONFLICT (perfil_id) DO UPDATE
       SET apagado_at       = EXCLUDED.apagado_at,
           apagado_por      = EXCLUDED.apagado_por,
           telegram_user_id = EXCLUDED.telegram_user_id;
    UPDATE bot_usuarios SET activo = false WHERE perfil_id = v_perfil AND activo;
  END IF;

  RETURN json_build_object(
    'success',          true,
    'telegram_user_id', p_telegram_user_id,
    'activo',           p_activo
  );
END;
$function$;

-- ---------------------------------------------------------------------------
-- 2 · Tablas de los envíos
-- ---------------------------------------------------------------------------
-- Una fila por (perfil, fecha, sucursal). Las viejas toman la sucursal del chat
-- que las recibió (era la de `/sucursal`, la que de hecho se resumió), o la
-- default del perfil.
ALTER TABLE public.bot_digests_enviados
  ADD COLUMN sucursal_id bigint REFERENCES public.sucursales(id) ON DELETE CASCADE;

UPDATE public.bot_digests_enviados d
   SET sucursal_id = COALESCE(
         (SELECT bu.sucursal_id FROM bot_usuarios bu WHERE bu.telegram_user_id = d.telegram_user_id),
         (SELECT us.sucursal_id FROM usuario_sucursales us
           WHERE us.usuario_id = d.admin_perfil_id
           ORDER BY (us.es_default IS TRUE) DESC, us.sucursal_id LIMIT 1));

ALTER TABLE public.bot_digests_enviados ALTER COLUMN sucursal_id SET NOT NULL;
ALTER TABLE public.bot_digests_enviados DROP CONSTRAINT bot_digests_enviados_pkey;
ALTER TABLE public.bot_digests_enviados
  ADD CONSTRAINT bot_digests_enviados_pkey PRIMARY KEY (admin_perfil_id, fecha, sucursal_id);

-- 'enviando': la marca que se toma antes de mandar (BOT-10).
ALTER TABLE public.bot_digests_enviados DROP CONSTRAINT bot_digests_enviados_status_check;
ALTER TABLE public.bot_digests_enviados ADD CONSTRAINT bot_digests_enviados_status_check
  CHECK (status IN ('enviando', 'ok', 'error', 'skipped'));
ALTER TABLE public.bot_avisos_atrasados_enviados DROP CONSTRAINT bot_avisos_atrasados_enviados_status_check;
ALTER TABLE public.bot_avisos_atrasados_enviados ADD CONSTRAINT bot_avisos_atrasados_enviados_status_check
  CHECK (status IN ('enviando', 'ok', 'error', 'skipped'));

COMMENT ON COLUMN public.bot_digests_enviados.sucursal_id IS
  'La sucursal resumida (#1309): un resumen por cada sucursal activa asignada al perfil, no la de /sucursal.';

-- BOT-10: confirmar un borrador que se canceló no es "pedido ya creado".
ALTER TABLE public.bot_pedidos_pendientes ADD COLUMN cancelado_at timestamptz;
COMMENT ON COLUMN public.bot_pedidos_pendientes.cancelado_at IS
  'Cuándo el usuario tocó "Cancelar" (#1311). consumido = true con cancelado_at NULL es un pedido creado.';

-- ---------------------------------------------------------------------------
-- 3 · BOT-1 / BOT-2: a quién le toca el resumen
-- ---------------------------------------------------------------------------
-- La única definición de "quién está suscripto al resumen, de qué sucursal, a
-- qué hora y con qué secciones". La consumen `bot_digest_pendientes` (la edge
-- function) y `auditoria_bot` (el gate): con dos copias, el gate miraría otra
-- cosa que lo que se manda.
CREATE FUNCTION public.bot_digest_suscripciones()
RETURNS TABLE (
  telegram_user_id bigint,
  perfil_id        uuid,
  nombre           text,
  rol              text,
  sucursal_id      bigint,
  sucursal_nombre  text,
  hora_local       smallint,
  dias_semana      smallint[],
  secciones        text[]
)
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  -- Un chat por perfil y sucursal: el último vinculado. Un perfil con dos chats
  -- prendidos (el admin re-prendió el viejo a mano) recibía el resumen en uno
  -- cualquiera, y el gate lo contaba dos veces.
  SELECT DISTINCT ON (bu.perfil_id, s.id)
    bu.telegram_user_id,
    bu.perfil_id,
    p.nombre::text,
    p.rol::text,
    s.id,
    s.nombre::text,
    COALESCE(c.hora_local,  7::SMALLINT),
    COALESCE(c.dias_semana, ARRAY[1,2,3,4,5,6,7]::SMALLINT[]),
    -- Lo que eligió, recortado a lo que su rol puede recibir: una fila
    -- escrita a mano con secciones de otro rol no le hace llegar nada ajeno.
    ARRAY(
      SELECT x FROM unnest(COALESCE(c.secciones, digest_secciones_default(p.rol))) x
       WHERE x = ANY (digest_secciones_del_rol(p.rol))
       ORDER BY x
    )
  FROM bot_usuarios bu
  JOIN perfiles p ON p.id = bu.perfil_id
  -- #1309 (BOT-2): una por cada sucursal ACTIVA asignada, no la de /sucursal
  -- (`bot_usuarios.sucursal_id`), y sin sucursal no hay resumen: NULL no es la
  -- Red.
  JOIN usuario_sucursales us ON us.usuario_id = bu.perfil_id
  JOIN sucursales s ON s.id = us.sucursal_id AND s.activa IS TRUE
  LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
  -- El rol y el alta salen de `perfiles`, no del snapshot de bot_usuarios
  -- (mig 237): el resumen le llega a quien HOY es admin o preventista.
  WHERE bu.activo AND p.activo AND p.rol IN ('admin', 'preventista')
    -- Admin: sin fila recibe el default, como siempre. Preventista: sin fila,
    -- nada (opt-in).
    AND COALESCE(c.activo, p.rol = 'admin')
  ORDER BY bu.perfil_id, s.id, bu.vinculado_at DESC, bu.telegram_user_id DESC;
$function$;

-- Lo que la edge function manda en esta corrida (BOT-1): a quien le toca hoy
-- (`p_dow`), desde su hora en adelante (`hora_local <= p_hora`), y todavía no
-- tiene marca para el día resumido (`p_fecha`, "ayer"). Un 'error' vuelve a
-- salir; 'enviando', 'ok' y 'skipped', no.
CREATE FUNCTION public.bot_digest_pendientes(p_fecha date, p_hora integer, p_dow integer)
RETURNS json
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    json_agg(
      json_build_object(
        'telegram_user_id', t.telegram_user_id,
        'perfil_id',        t.perfil_id,
        'rol',              t.rol,
        'sucursal_id',      t.sucursal_id,
        'sucursal_nombre',  t.sucursal_nombre,
        'secciones',        t.secciones
      )
      ORDER BY t.telegram_user_id, t.sucursal_id
    ),
    '[]'::json
  )
  FROM bot_digest_suscripciones() t
  WHERE t.hora_local <= p_hora::SMALLINT
    AND p_dow::SMALLINT = ANY (t.dias_semana)
    -- Sin secciones no hay mensaje que mandar.
    AND array_length(t.secciones, 1) >= 1
    AND NOT EXISTS (
      SELECT 1 FROM bot_digests_enviados d
       WHERE d.admin_perfil_id = t.perfil_id
         AND d.fecha = p_fecha
         AND d.sucursal_id = t.sucursal_id
         AND d.status <> 'error'
    );
$function$;

-- La vieja, con la hora exacta y la sucursal de /sucursal. La edge function de
-- este PR ya llama a bot_digest_pendientes (ver ORDEN en la cabecera).
DROP FUNCTION public.bot_digest_destinatarios(integer, integer);

-- La marca, antes de mandar (BOT-10). TRUE = esta corrida lo manda. De dos
-- corridas a la vez, el INSERT de una gana y la otra no ve fila que actualizar.
-- Un 'error' anterior se retoma; un 'enviando' no (ver la cabecera).
CREATE FUNCTION public.bot_digest_reservar(
  p_perfil_id uuid, p_sucursal_id bigint, p_fecha date, p_telegram_user_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ok boolean;
BEGIN
  INSERT INTO bot_digests_enviados AS d
    (admin_perfil_id, fecha, sucursal_id, telegram_user_id, status, sent_at, error_meta)
  VALUES (p_perfil_id, p_fecha, p_sucursal_id, p_telegram_user_id, 'enviando', now(), NULL)
  ON CONFLICT (admin_perfil_id, fecha, sucursal_id) DO UPDATE
     SET status           = 'enviando',
         sent_at          = now(),
         telegram_user_id = EXCLUDED.telegram_user_id,
         error_meta       = NULL
   WHERE d.status = 'error'
  RETURNING true INTO v_ok;
  RETURN COALESCE(v_ok, false);
END;
$function$;

-- Cierra la marca que tomó `bot_digest_reservar`.
CREATE FUNCTION public.bot_digest_registrar(
  p_perfil_id uuid, p_sucursal_id bigint, p_fecha date, p_status text, p_error_meta jsonb DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  IF p_status NOT IN ('ok', 'error', 'skipped') THEN
    RAISE EXCEPTION 'bot_digest_registrar: status inválido %', p_status;
  END IF;
  UPDATE bot_digests_enviados
     SET status = p_status, sent_at = now(), error_meta = p_error_meta
   WHERE admin_perfil_id = p_perfil_id AND fecha = p_fecha AND sucursal_id = p_sucursal_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'bot_digest_registrar: no hay marca para (%, %, %)', p_perfil_id, p_fecha, p_sucursal_id;
  END IF;
END;
$function$;

-- El aviso semanal de atrasados (mig 325), con el mismo criterio: desde su hora
-- y si todavía no lo recibió hoy (día argentino).
CREATE OR REPLACE FUNCTION public.bot_aviso_atrasados_destinatarios(p_hora integer, p_dow integer)
 RETURNS json
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
  SELECT COALESCE(json_agg(json_build_object(
           'telegram_user_id', bu.telegram_user_id,
           'perfil_id',        bu.perfil_id,
           'sucursal_id',      bu.sucursal_id
         ) ORDER BY bu.telegram_user_id), '[]'::json)
    FROM bot_usuarios bu
    JOIN perfiles p ON p.id = bu.perfil_id
    LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
   WHERE bu.activo AND p.activo AND p.rol = 'preventista'
     AND bu.sucursal_id IS NOT NULL
     -- Activado por defecto (decisión del dueño, 2026-10-09).
     AND COALESCE(c.aviso_atrasados_activo, TRUE)
     -- #1309: desde su hora, no sólo dentro de ella. El cron horario de GitHub
     -- se saltea horas.
     AND COALESCE(c.aviso_atrasados_hora, 8) <= p_hora::SMALLINT
     AND p_dow::SMALLINT = ANY (COALESCE(c.aviso_atrasados_dias, ARRAY[1]::SMALLINT[]))
     AND NOT EXISTS (
       SELECT 1 FROM bot_avisos_atrasados_enviados a
        WHERE a.perfil_id = bu.perfil_id
          AND a.fecha = public._tablero_hoy()
          AND a.status <> 'error'
     );
$function$;

CREATE FUNCTION public.bot_aviso_atrasados_reservar(
  p_perfil_id uuid, p_fecha date, p_telegram_user_id bigint
)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_ok boolean;
BEGIN
  INSERT INTO bot_avisos_atrasados_enviados AS a
    (perfil_id, fecha, telegram_user_id, status, sent_at, error_meta)
  VALUES (p_perfil_id, p_fecha, p_telegram_user_id, 'enviando', now(), NULL)
  ON CONFLICT (perfil_id, fecha) DO UPDATE
     SET status           = 'enviando',
         sent_at          = now(),
         telegram_user_id = EXCLUDED.telegram_user_id,
         error_meta       = NULL
   WHERE a.status = 'error'
  RETURNING true INTO v_ok;
  RETURN COALESCE(v_ok, false);
END;
$function$;

-- ---------------------------------------------------------------------------
-- 4 · El gate (#1309 y #1311)
-- ---------------------------------------------------------------------------
-- Lo llama scripts/check-bot.mjs con service_role desde integridad.yml.
--   · digest_faltantes: a quién le tocaba un resumen entre hace 30 y hace 2
--     horas (su hora, un día de los suyos) y no tiene 'ok' ni 'skipped' para ese
--     día. Las 2 horas de gracia cubren el atraso del cron; las 30, el día más
--     el atraso del propio gate (con 24 justas, un gate que un día corre 08:10
--     y al siguiente 09:10 se saltea un resumen sin mirarlo). Un resumen se
--     puede mirar en dos corridas seguidas: la segunda dice lo mismo.
--   · sin_sucursal: suscriptos al resumen (como en bot_digest_suscripciones,
--     sin el JOIN a la sucursal) que no tienen ninguna sucursal activa. Antes
--     recibían la Red; ahora no reciben nada.
--   · apagado: el trigger que sostiene la decisión de #1311 está y está
--     habilitado, y ningún chat de un perfil marcado está prendido.
CREATE FUNCTION public.auditoria_bot()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  WITH dias AS (
    SELECT public._tablero_hoy() AS d
    UNION ALL
    SELECT public._tablero_hoy() - 1
    UNION ALL
    SELECT public._tablero_hoy() - 2
  ),
  esperados AS (
    SELECT s.perfil_id, s.nombre, s.sucursal_id, s.sucursal_nombre,
           d.d AS dia_envio, (d.d - 1) AS fecha_resumida,
           (d.d + make_interval(hours => s.hora_local)) AT TIME ZONE 'America/Argentina/Buenos_Aires' AS momento
      FROM bot_digest_suscripciones() s
      CROSS JOIN dias d
     WHERE array_length(s.secciones, 1) >= 1
       AND EXTRACT(ISODOW FROM d.d)::SMALLINT = ANY (s.dias_semana)
  ),
  faltantes AS (
    SELECT e.*,
           (SELECT x.status FROM bot_digests_enviados x
             WHERE x.admin_perfil_id = e.perfil_id AND x.fecha = e.fecha_resumida
               AND x.sucursal_id = e.sucursal_id) AS status
      FROM esperados e
     WHERE e.momento <= now() - interval '2 hours'
       AND e.momento >  now() - interval '30 hours'
       AND NOT EXISTS (
         SELECT 1 FROM bot_digests_enviados x
          WHERE x.admin_perfil_id = e.perfil_id
            AND x.fecha = e.fecha_resumida
            AND x.sucursal_id = e.sucursal_id
            AND x.status IN ('ok', 'skipped')
       )
  )
  SELECT jsonb_build_object(
    'generado_at', now(),
    'suscripciones', (SELECT count(*) FROM bot_digest_suscripciones()),
    'digest_faltantes', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
               'perfil_id', f.perfil_id, 'nombre', f.nombre,
               'sucursal_id', f.sucursal_id, 'sucursal', f.sucursal_nombre,
               'fecha_resumida', f.fecha_resumida, 'momento', f.momento,
               'status', f.status
             ) ORDER BY f.momento, f.nombre, f.sucursal_id)
        FROM faltantes f), '[]'::jsonb),
    'sin_sucursal', COALESCE((
      SELECT jsonb_agg(DISTINCT jsonb_build_object('perfil_id', p.id, 'nombre', p.nombre))
        FROM bot_usuarios bu
        JOIN perfiles p ON p.id = bu.perfil_id
        LEFT JOIN bot_digest_config c ON c.perfil_id = bu.perfil_id
       WHERE bu.activo AND p.activo AND p.rol IN ('admin', 'preventista')
         AND COALESCE(c.activo, p.rol = 'admin')
         AND NOT EXISTS (SELECT 1 FROM usuario_sucursales us
                           JOIN sucursales s ON s.id = us.sucursal_id AND s.activa IS TRUE
                          WHERE us.usuario_id = bu.perfil_id)), '[]'::jsonb),
    'apagado', jsonb_build_object(
      'trigger_ok', EXISTS (
        SELECT 1 FROM pg_trigger t
         WHERE t.tgrelid = 'public.bot_usuarios'::regclass
           AND t.tgname = 'trg_bot_usuarios_respeta_apagado'
           AND t.tgenabled <> 'D'
           AND t.tgfoid = 'public.bot_usuarios_respeta_apagado()'::regprocedure),
      'chats_prendidos_con_marca', (
        SELECT count(*) FROM bot_usuarios bu
          JOIN bot_apagados_por_admin a ON a.perfil_id = bu.perfil_id
         WHERE bu.activo)
    )
  );
$function$;

-- ---------------------------------------------------------------------------
-- 5 · Parches por ancla sobre el cuerpo vivo (md5 verificado en el paso 0)
-- ---------------------------------------------------------------------------
CREATE TEMP TABLE _bot_parche (
  orden     serial,
  firma     text NOT NULL,
  veces     int  NOT NULL,
  ancla     text NOT NULL,
  reemplazo text NOT NULL
) ON COMMIT DROP;

INSERT INTO _bot_parche (firma, veces, ancla, reemplazo) VALUES
-- BOT-3: "Tomados" (y su promedio de 7 días, para que el delta compare lo mismo)
-- sin las comandas de canje.
('public.bot_metricas_admin_dia(date,bigint)', 2,
$a$      AND estado <> 'cancelado'
      AND tipo_factura IS DISTINCT FROM 'VB'$a$,
$r$      AND estado <> 'cancelado'
      AND canal <> 'cambio'  -- #1310 (BOT-3): una comanda de canje no es un pedido tomado
      AND tipo_factura IS DISTINCT FROM 'VB'$r$),
-- BOT-3: el stock crítico, sólo de lo que se vende (como bot_stock_y_ventas).
('public.bot_metricas_admin_dia(date,bigint)', 1,
$a$    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
$a$,
$r$    WHERE COALESCE(stock, 0) <= COALESCE(stock_minimo, 10)
      AND activo  -- #1310 (BOT-3): un producto dado de baja no se repone
$r$),
-- BOT-4: el top de productos del resumen cuenta unidades vendidas, no regalos.
('public.bot_metricas_admin_dia(date,bigint)', 1,
$a$    JOIN pedidos_dia  pd ON pd.id = pi.pedido_id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
$a$,
$r$    JOIN pedidos_dia  pd ON pd.id = pi.pedido_id
    LEFT JOIN productos pr ON pr.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE  -- #1310 (BOT-4): un regalo no es una unidad vendida
$r$),
-- BOT-4: el ranking de preventistas por producto, la base de los concursos.
('public.bot_ranking_preventistas_por_producto(bigint[],date,date,bigint,integer)', 1,
$a$      AND pi.producto_id = ANY(p_producto_ids)
$a$,
$r$      AND pi.producto_id = ANY(p_producto_ids)
      AND pi.es_bonificacion IS NOT TRUE  -- #1310 (BOT-4): un regalo no es una unidad vendida
$r$),
-- BOT-4: el top de productos del período.
('public.bot_ventas_periodo(date,date,bigint,integer)', 1,
$a$    JOIN productos p ON p.id = pi.producto_id
    GROUP BY p.id, p.codigo, p.nombre
$a$,
$r$    JOIN productos p ON p.id = pi.producto_id
    WHERE pi.es_bonificacion IS NOT TRUE  -- #1310 (BOT-4): un regalo no es una unidad vendida
    GROUP BY p.id, p.codigo, p.nombre
$r$),
-- BOT-7: el mismo recorrido que bot_mi_recorrido (el último del día).
('public.bot_recorrido_resumen(uuid,bigint,date)', 1,
$a$    AND r.sucursal_id = p_sucursal_id AND r.fecha = p_fecha;$a$,
$r$    AND r.sucursal_id = p_sucursal_id AND r.fecha = p_fecha
  -- #1310 (BOT-7): con dos recorridos en el día, el mismo que bot_mi_recorrido.
  ORDER BY r.id DESC
  LIMIT 1;$r$),
-- BOT-8: las compras son la venta de CLAUDE.md (entregado, sin canjes, sin VB,
-- sin envío). Las otras líneas del subselect (canal y VB) quedan como estaban.
('public.obtener_resumen_cuenta_cliente_bot(integer)', 1,
$a$'total_compras', (SELECT COALESCE(SUM(total), 0) FROM pedidos
                       WHERE cliente_id = p_cliente_id AND estado IS DISTINCT FROM 'cancelado'$a$,
$r$'total_compras', (SELECT COALESCE(SUM(GREATEST(total - cargo_envio, 0)), 0) FROM pedidos  -- #1310 (BOT-8): la venta
                       WHERE cliente_id = p_cliente_id AND estado = 'entregado'$r$),
-- BOT-6: el encargado ve los clientes asignados de su sucursal, como en la ficha.
('public.bot_buscar_cliente(text,uuid,text,bigint,integer)', 1,
$a$      p_rol = 'admin'
      OR EXISTS($a$,
$r$      p_rol IN ('admin', 'encargado')  -- #1311 (BOT-6): como la rama de reservado y la ficha
      OR EXISTS($r$),
-- BOT-2: el historial del panel nombra la sucursal resumida, no la de /sucursal.
('public.bot_admin_digests_enviados(date,date)', 1,
$a$    LEFT JOIN bot_usuarios bu ON bu.telegram_user_id = d.telegram_user_id
    LEFT JOIN sucursales  s ON s.id = bu.sucursal_id
$a$,
$r$    LEFT JOIN sucursales  s ON s.id = d.sucursal_id  -- #1309: la sucursal resumida
$r$),
('public.bot_admin_digests_enviados(date,date)', 1,
$a$      s.nombre   AS sucursal_nombre,
$a$,
$r$      s.nombre   AS sucursal_nombre,
      d.sucursal_id,
$r$),
-- BOT-5: el canje no prende a quien apagó un admin, desde ningún chat. El
-- código se quema (no se puede reintentar) y no cuenta como intento fallido: es
-- un código válido.
('public.canjear_codigo_vinculacion_bot(text,bigint,text)', 1,
$a$  -- 4) Sucursal default del perfil$a$,
$r$  -- 3b) Apagado por un admin (#1311, decisión del dueño 29/10): definitivo
  --     hasta que un admin lo prenda desde el panel. La marca es del perfil, así
  --     que vincular otro Telegram tampoco la saltea.
  --     Y un chat cuyo dueño actual está marcado no se le pasa a otro perfil: el
  --     apagado quedaría sin fila en el panel desde donde prenderlo.
  IF EXISTS (SELECT 1 FROM bot_apagados_por_admin a WHERE a.perfil_id = v_perfil_id)
     OR EXISTS (SELECT 1 FROM bot_usuarios bu
                  JOIN bot_apagados_por_admin a ON a.perfil_id = bu.perfil_id
                 WHERE bu.telegram_user_id = p_telegram_user_id) THEN
    UPDATE bot_codigos_vinculacion
       SET usado_at = now(),
           usado_por_telegram_id = p_telegram_user_id
     WHERE codigo = p_codigo;
    RETURN jsonb_build_object('success', false, 'error', 'apagado_por_admin');
  END IF;

  -- 4) Sucursal default del perfil$r$),
-- BOT-5: ni siquiera se genera el código.
('public.generar_codigo_vinculacion_bot()', 1,
$a$    RAISE EXCEPTION 'No autenticado';
  END IF;
$a$,
$r$    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- #1311: a quien un admin le apagó el bot, sólo un admin se lo prende.
  IF EXISTS (SELECT 1 FROM bot_apagados_por_admin a WHERE a.perfil_id = auth.uid()) THEN
    RAISE EXCEPTION 'Un administrador te apagó el bot de Telegram. Pedile que lo vuelva a prender desde el panel del bot.';
  END IF;
$r$);

DO $parches$
DECLARE
  v_f   record;
  v_p   record;
  v_def text;
  v_n   int;
BEGIN
  FOR v_f IN SELECT DISTINCT firma FROM _bot_parche ORDER BY firma LOOP
    v_def := pg_get_functiondef(v_f.firma::regprocedure);
    FOR v_p IN SELECT * FROM _bot_parche WHERE firma = v_f.firma ORDER BY orden LOOP
      v_n := (length(v_def) - length(replace(v_def, v_p.ancla, ''))) / length(v_p.ancla);
      IF v_n <> v_p.veces THEN
        RAISE EXCEPTION 'mig NNN · % parche %: el ancla aparece % vez/veces y se esperaba %',
          v_f.firma, v_p.orden, v_n, v_p.veces;
      END IF;
      v_def := replace(v_def, v_p.ancla, v_p.reemplazo);
    END LOOP;
    EXECUTE v_def;
  END LOOP;
END
$parches$;

-- ---------------------------------------------------------------------------
-- 6 · Permisos de las nuevas: todas de server (la edge function y el gate)
-- ---------------------------------------------------------------------------
REVOKE ALL ON FUNCTION public.bot_digest_suscripciones() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bot_digest_pendientes(date, integer, integer) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bot_digest_reservar(uuid, bigint, date, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bot_digest_registrar(uuid, bigint, date, text, jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.bot_aviso_atrasados_reservar(uuid, date, bigint) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.auditoria_bot() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.bot_digest_suscripciones() TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_digest_pendientes(date, integer, integer) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_digest_reservar(uuid, bigint, date, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_digest_registrar(uuid, bigint, date, text, jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION public.bot_aviso_atrasados_reservar(uuid, date, bigint) TO service_role;
GRANT EXECUTE ON FUNCTION public.auditoria_bot() TO service_role;

-- ---------------------------------------------------------------------------
-- 7 · Ensayo, dentro de la transacción (todo vuelve atrás con un SAVEPOINT)
-- ---------------------------------------------------------------------------
-- Lo que hace falta que sea cierto antes del COMMIT. El ensayo largo, con datos
-- armados, es scripts/test-bot-1309-1311.sql.
DO $ensayo$
DECLARE
  v_perfil   uuid;
  v_tg       bigint;
  v_r        jsonb;
  v_n        int;
  v_suc      bigint;
BEGIN
  -- El backfill dejó todo con sucursal y la PK nueva no choca.
  IF EXISTS (SELECT 1 FROM bot_digests_enviados WHERE sucursal_id IS NULL) THEN
    RAISE EXCEPTION 'mig NNN · ensayo: quedaron envíos sin sucursal';
  END IF;

  -- Las pendientes de "ayer" a las 23 no incluyen a quien ya tiene 'ok'.
  SELECT count(*) INTO v_n
    FROM json_array_elements(public.bot_digest_pendientes(public._tablero_hoy() - 1, 23,
           EXTRACT(ISODOW FROM public._tablero_hoy())::int)) e
    JOIN bot_digests_enviados d
      ON d.admin_perfil_id = (e->>'perfil_id')::uuid
     AND d.sucursal_id = (e->>'sucursal_id')::bigint
     AND d.fecha = public._tablero_hoy() - 1
     AND d.status <> 'error';
  IF v_n <> 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: bot_digest_pendientes devuelve % ya enviados', v_n;
  END IF;

  -- Reservar dos veces: la segunda pierde. Con 'error', se retoma.
  SELECT s.perfil_id, s.sucursal_id, s.telegram_user_id INTO v_perfil, v_suc, v_tg
    FROM bot_digest_suscripciones() s LIMIT 1;
  IF v_perfil IS NOT NULL THEN
    IF NOT public.bot_digest_reservar(v_perfil, v_suc, DATE '1999-01-01', v_tg) THEN
      RAISE EXCEPTION 'mig NNN · ensayo: la primera reserva no ganó';
    END IF;
    IF public.bot_digest_reservar(v_perfil, v_suc, DATE '1999-01-01', v_tg) THEN
      RAISE EXCEPTION 'mig NNN · ensayo: la segunda reserva también ganó (doble envío)';
    END IF;
    PERFORM public.bot_digest_registrar(v_perfil, v_suc, DATE '1999-01-01', 'error', '{"stage":"ensayo"}');
    IF NOT public.bot_digest_reservar(v_perfil, v_suc, DATE '1999-01-01', v_tg) THEN
      RAISE EXCEPTION 'mig NNN · ensayo: un error no se pudo retomar';
    END IF;
    DELETE FROM bot_digests_enviados WHERE fecha = DATE '1999-01-01';
  END IF;

  -- #1311: con la marca, ningún chat del perfil se prende.
  SELECT bu.perfil_id, bu.telegram_user_id INTO v_perfil, v_tg
    FROM bot_usuarios bu WHERE bu.activo LIMIT 1;
  IF v_perfil IS NOT NULL THEN
    BEGIN
      INSERT INTO bot_apagados_por_admin (perfil_id, telegram_user_id) VALUES (v_perfil, v_tg);
      UPDATE bot_usuarios SET activo = false WHERE perfil_id = v_perfil;
      BEGIN
        UPDATE bot_usuarios SET activo = true WHERE telegram_user_id = v_tg;
        RAISE EXCEPTION 'mig NNN · ensayo: se prendió un chat de un perfil apagado por el admin';
      EXCEPTION WHEN check_violation THEN
        NULL;  -- lo esperado
      END;
      -- Rollback del bloque: la marca y el apagado de arriba no quedan.
      RAISE EXCEPTION USING ERRCODE = 'P0B01', MESSAGE = 'fin del ensayo';
    EXCEPTION WHEN SQLSTATE 'P0B01' THEN
      NULL;
    END;
    IF NOT (SELECT activo FROM bot_usuarios WHERE telegram_user_id = v_tg) THEN
      RAISE EXCEPTION 'mig NNN · ensayo: el bloque del apagado no volvió atrás';
    END IF;
  END IF;

  -- El gate corre y ve el trigger.
  v_r := public.auditoria_bot();
  IF NOT (v_r -> 'apagado' ->> 'trigger_ok')::boolean
     OR (v_r -> 'apagado' ->> 'chats_prendidos_con_marca')::int <> 0 THEN
    RAISE EXCEPTION 'mig NNN · ensayo: el gate del apagado no da verde: %', v_r -> 'apagado';
  END IF;

  RAISE NOTICE 'mig NNN · ensayo ok: % suscripciones, % resúmenes faltantes en las últimas 30 h',
    v_r ->> 'suscripciones', jsonb_array_length(v_r -> 'digest_faltantes');
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 8 · Lo parcheado quedó parcheado
-- ---------------------------------------------------------------------------
DO $post$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.marca FROM (VALUES
      ('public.bot_metricas_admin_dia(date,bigint)',                                     '#1310 (BOT-3): un producto dado de baja'),
      ('public.bot_ranking_preventistas_por_producto(bigint[],date,date,bigint,integer)', '#1310 (BOT-4)'),
      ('public.bot_ventas_periodo(date,date,bigint,integer)',                            '#1310 (BOT-4)'),
      ('public.bot_recorrido_resumen(uuid,bigint,date)',                                 '#1310 (BOT-7)'),
      ('public.obtener_resumen_cuenta_cliente_bot(integer)',                             '#1310 (BOT-8)'),
      ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',                       '#1311 (BOT-6)'),
      ('public.bot_admin_digests_enviados(date,date)',                                   'd.sucursal_id'),
      ('public.canjear_codigo_vinculacion_bot(text,bigint,text)',                        'apagado_por_admin'),
      ('public.generar_codigo_vinculacion_bot()',                                        'bot_apagados_por_admin')
    ) AS x(firma, marca)
  LOOP
    IF position(v_f.marca in pg_get_functiondef(v_f.firma::regprocedure)) = 0 THEN
      RAISE EXCEPTION 'mig NNN · % no quedó parcheada', v_f.firma;
    END IF;
  END LOOP;
END
$post$;

-- ---------------------------------------------------------------------------
-- 9 · Los permisos quedaron como estaban (y las nuevas, sólo de server)
-- ---------------------------------------------------------------------------
DO $acl$
DECLARE
  v_f record;
BEGIN
  FOR v_f IN
    SELECT x.firma, x.auth FROM (VALUES
      ('public.bot_metricas_admin_dia(date,bigint)',                                     false),
      ('public.bot_ranking_preventistas_por_producto(bigint[],date,date,bigint,integer)', false),
      ('public.bot_ventas_periodo(date,date,bigint,integer)',                            false),
      ('public.bot_recorrido_resumen(uuid,bigint,date)',                                 false),
      ('public.obtener_resumen_cuenta_cliente_bot(integer)',                             false),
      ('public.bot_buscar_cliente(text,uuid,text,bigint,integer)',                       false),
      ('public.canjear_codigo_vinculacion_bot(text,bigint,text)',                        false),
      ('public.bot_aviso_atrasados_destinatarios(integer,integer)',                      false),
      ('public.bot_digest_suscripciones()',                                              false),
      ('public.bot_digest_pendientes(date,integer,integer)',                             false),
      ('public.bot_digest_reservar(uuid,bigint,date,bigint)',                            false),
      ('public.bot_digest_registrar(uuid,bigint,date,text,jsonb)',                       false),
      ('public.bot_aviso_atrasados_reservar(uuid,date,bigint)',                          false),
      ('public.auditoria_bot()',                                                         false),
      ('public.bot_usuarios_respeta_apagado()',                                          false),
      ('public.bot_admin_digests_enviados(date,date)',                                   true),
      ('public.bot_admin_toggle_usuario(bigint,boolean)',                                true),
      ('public.generar_codigo_vinculacion_bot()',                                        true)
    ) AS x(firma, auth)
  LOOP
    IF has_function_privilege('anon', v_f.firma, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó ejecutable con la anon key', v_f.firma;
    END IF;
    IF has_function_privilege('authenticated', v_f.firma, 'EXECUTE') <> v_f.auth THEN
      RAISE EXCEPTION 'mig NNN · % quedó con EXECUTE para authenticated = %, se esperaba %',
        v_f.firma, NOT v_f.auth, v_f.auth;
    END IF;
    IF NOT has_function_privilege('service_role', v_f.firma, 'EXECUTE') THEN
      RAISE EXCEPTION 'mig NNN · % quedó sin EXECUTE para service_role', v_f.firma;
    END IF;
    IF NOT (SELECT prosecdef FROM pg_proc WHERE oid = v_f.firma::regprocedure) THEN
      RAISE EXCEPTION 'mig NNN · % dejó de ser SECURITY DEFINER', v_f.firma;
    END IF;
  END LOOP;

  IF has_table_privilege('authenticated', 'public.bot_apagados_por_admin', 'SELECT')
     OR has_table_privilege('anon', 'public.bot_apagados_por_admin', 'SELECT') THEN
    RAISE EXCEPTION 'mig NNN · bot_apagados_por_admin quedó legible por REST';
  END IF;
END
$acl$;

COMMIT;
