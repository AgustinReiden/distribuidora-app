-- 254 · Un bot callado no es un gate rojo
--
-- BOT-A (mig 252, #661) baja de `high` a `medium`.
--
-- El check mide filas de `bot_audit_log` de mas de 100 dias, y quien las barre es
-- el trigger `trg_bot_audit_log_retencion`, que corre AL ESCRIBIR. Los dos
-- hechos juntos tienen una consecuencia que no se penso al ponerlo en `high`:
-- si el bot se queda callado --se cae, se apaga, nadie le escribe-- no hay
-- INSERT que dispare el barrido, la fila mas vieja envejece sola y el check se
-- pone rojo sin que haya nada roto en la base.
--
-- En `high` eso tumba `overall_ok` y con el al gate de CI
-- (`scripts/check-integridad.mjs`), o sea que un bot mudo bloquea el merge de
-- cualquier rama. Ese es justo el modo de falla que la 244 documento al reves:
-- un gate permanentemente rojo se ignora igual que uno permanentemente verde.
--
-- En `medium` el check sigue existiendo, sigue contando y se sigue viendo en la
-- auditoria --que es lo que se pedia: algo que hubiera avisado hace cinco
-- meses-- pero no tumba el gate. `overall_ok` sólo mira `critical` y `high`.
--
-- Lo que NO cambia: el umbral (100 dias), la consulta, ni la retencion de la
-- 252. Un atraso REAL de la retencion --el bot escribiendo y el barrido sin
-- correr-- se sigue viendo igual; lo unico que cambia es que avisa en vez de
-- trabar.
--
-- Tecnica: parche por ancla sobre el cuerpo vivo (molde de la 241/242/244/252).

BEGIN;

-- ---------------------------------------------------------------------------
-- 0 · Andamio: parche por ancla, con la guarda de "exactamente una vez".
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public._migsv_ancla(
  p_funcion regprocedure, p_ancla text, p_nuevo text
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

-- ---------------------------------------------------------------------------
-- 1 · BOT-A: high -> medium.
--
--     El ancla incluye la consulta entera para que el parche falle si alguien
--     le cambio el umbral o el criterio: en ese caso la severidad no es lo
--     unico que hay que mirar.
-- ---------------------------------------------------------------------------
DO $patch$
BEGIN
  PERFORM public._migsv_ancla('public.auditoria_integridad()'::regprocedure,
$ancla$    ('BOT-A','high','bot_audit_log sin filas de mas de 100 dias: la retencion al escribir sigue viva (mig 252, #661)',
      (SELECT count(*) FROM bot_audit_log WHERE created_at < now() - INTERVAL '100 days')),$ancla$,
$nuevo$    -- mig 254: medium y no high a proposito. El barrido corre AL ESCRIBIR
    -- (trg_bot_audit_log_retencion), asi que un bot callado mas de 100 dias
    -- pone esto en rojo sin que haya nada roto. En high eso tumbaba overall_ok
    -- y trababa el merge de cualquier rama por un bot apagado.
    ('BOT-A','medium','bot_audit_log sin filas de mas de 100 dias: la retencion al escribir sigue viva (mig 252, #661)',
      (SELECT count(*) FROM bot_audit_log WHERE created_at < now() - INTERVAL '100 days')),$nuevo$);
END
$patch$;

-- ---------------------------------------------------------------------------
-- 2 · El ensayo: BOT-A existe, es medium, y no tumba overall_ok cuando falla.
--
--     La segunda mitad es la que importa: se siembra una fila vieja, se
--     verifica que el check la VE (sigue midiendo) y que aun asi overall_ok
--     sigue en true. El sub-bloque se deshace solo con el centinela.
-- ---------------------------------------------------------------------------
DO $ensayo$
DECLARE
  v_j        jsonb;
  v_bot      jsonb;
  v_ok       boolean;
  v_fila     bigint;
BEGIN
  BEGIN
    v_j := public.auditoria_integridad();
    SELECT c INTO v_bot FROM jsonb_array_elements(v_j->'checks') c WHERE c->>'id' = 'BOT-A';

    IF v_bot IS NULL THEN
      RAISE EXCEPTION 'migsv . BOT-A desaparecio de auditoria_integridad';
    END IF;
    IF v_bot->>'severidad' <> 'medium' THEN
      RAISE EXCEPTION 'migsv . BOT-A quedo en severidad % (esperado medium)', v_bot->>'severidad';
    END IF;
    IF NOT (v_j->>'overall_ok')::boolean THEN
      RAISE EXCEPTION 'migsv . overall_ok arranca en false: la 254 no es la culpable, pero hay que mirarlo';
    END IF;

    -- Un bot callado: una fila que envejecio sin que nadie escriba despues.
    --
    -- Ojo con como se siembra. El barrido es AFTER INSERT FOR EACH STATEMENT,
    -- asi que una fila vieja insertada de una la borra su PROPIO insert: el
    -- trigger corre al final del statement que la metio. Por eso se inserta
    -- fresca y se la envejece con un UPDATE, que no dispara nada. (De paso
    -- queda medido que la retencion de la 252 aguanta incluso una fila vieja
    -- que entra hoy.)
    INSERT INTO bot_audit_log (tipo, texto_usuario)
         VALUES ('mensaje', 'ZZ ensayo mig254 bot callado')
      RETURNING id INTO v_fila;
    UPDATE bot_audit_log SET created_at = now() - interval '365 days' WHERE id = v_fila;

    v_j := public.auditoria_integridad();
    SELECT c INTO v_bot FROM jsonb_array_elements(v_j->'checks') c WHERE c->>'id' = 'BOT-A';
    v_ok := (v_j->>'overall_ok')::boolean;

    -- Sigue midiendo...
    IF (v_bot->>'violaciones')::int < 1 OR (v_bot->>'ok')::boolean THEN
      RAISE EXCEPTION 'migsv . BOT-A no vio la fila vieja: violaciones=%, ok=%',
        v_bot->>'violaciones', v_bot->>'ok';
    END IF;
    -- ...pero ya no traba el gate.
    IF NOT v_ok THEN
      RAISE EXCEPTION 'migsv . un bot callado sigue tumbando overall_ok: BOT-A no quedo en medium';
    END IF;

    RAISE NOTICE 'migsv . ensayo OK: BOT-A avisa sin trabar';
    RAISE EXCEPTION 'migsv-ok' USING ERRCODE = '2F000';
  EXCEPTION WHEN SQLSTATE '2F000' THEN
    IF SQLERRM <> 'migsv-ok' THEN RAISE; END IF;
  END;
END
$ensayo$;

-- ---------------------------------------------------------------------------
-- 3 · Se saca el andamio.
-- ---------------------------------------------------------------------------
DROP FUNCTION public._migsv_ancla(regprocedure, text, text);

COMMIT;
