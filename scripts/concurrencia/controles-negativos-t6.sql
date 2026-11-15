-- Controles negativos de la tarjeta 6 de #1477 (#1473), grupo 1: ADV-5, ADV-2 y ADV-3. Se corren sobre la copia LOCAL
-- de Docker con la migración de la tarjeta aplicada. NUNCA contra prod ni contra una rama de Supabase compartida: es
-- DDL sobre `public`.
--
-- Van juntas porque cada una toca una función distinta y cada variante pasa por una sola:
--   M61 cambiar_cliente_pedido no pre-bloquea los productos ni las promos de los ítems nuevos (sólo los de X): T6d
--       vuelve a dar 40P01 en casi todas las rondas, y T6e (sin forzar) en una parte. T6a a T6c no dependen de esto
--       (los ítems nuevos son los de X).
--   M62 cambiar_regalo_promocion no toma los productos antes que la promo (desde #1491, la pasada por id de los KEY
--       SHARE y los contenedores), y authenticated recupera el UPDATE REST del regalo y del contenedor: T6g y T6h
--       vuelven a dar 40P01, y T6f también (por REST, sin el 42501). Del guardado entero (#1491), T6k y T6n
--       también. T6l y T6m mordían hasta #1501 y ya no: con la migración de #1501 el trigger de sentencia no relee
--       los contenedores dentro de la RPC, y sin el pre-bloqueo la RPC igual le avisa que están tomados, así que en
--       esos dos guiones no queda otro lock del contenedor después de la promo (medido el 07/11). El arreglo de
--       #1501 tiene su propio control: controles-negativos-t6o.sql.
--   M63 actualizar_precios_masivo espera hasta 60 s por producto: T6j vuelve a caer entera (57014 / 55P03).
-- El grupo 2 (ADV-1, el pre-bloqueo de productos entero) está en controles-negativos-t6b.sql: toca la misma función que
-- M61, así que no va junto.
--
--   psql -f controles-negativos-t6.sql
--   node run.mjs t6 --out <dir>   (otra carpeta que la de la corrida limpia)
--   RESTAURAR (más abajo) y repetir `docker-local.mjs huella`: cero diferencias.

-- ===== MUTAR =====
CREATE TABLE IF NOT EXISTS conc.mut_orig (firma text PRIMARY KEY, def text NOT NULL);
INSERT INTO conc.mut_orig SELECT p.oid::regprocedure::text, pg_get_functiondef(p.oid)
  FROM pg_proc p WHERE p.pronamespace = 'public'::regnamespace
   AND p.proname IN ('cambiar_cliente_pedido', 'cambiar_regalo_promocion', 'actualizar_precios_masivo')
ON CONFLICT DO NOTHING;
DO $m$
DECLARE
  d text; f text; pat text; rep text;
BEGIN
  FOR f, pat, rep IN SELECT v.f, v.pat, v.rep FROM (VALUES
      ('cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
       E'    UNION\n    SELECT btrim(e->>''promocion_id'')::bigint FROM jsonb_array_elements(p_items) e\n     WHERE btrim(COALESCE(e->>''promocion_id'', '''')) ~ ''^[0-9]{1,18}$'');',
       E'    UNION\n    SELECT btrim(e->>''promocion_id'')::bigint FROM jsonb_array_elements(p_items) e\n     WHERE false /* MUTADO */ AND btrim(COALESCE(e->>''promocion_id'', '''')) ~ ''^[0-9]{1,18}$'');'),
      ('cambiar_cliente_pedido(bigint,bigint,uuid,jsonb,numeric,numeric,numeric,text,text)',
       E'                  WHERE btrim(COALESCE(e->>''producto_id'', '''')) ~ ''^[0-9]{1,18}$''',
       E'                  WHERE false /* MUTADO */ AND btrim(COALESCE(e->>''producto_id'', '''')) ~ ''^[0-9]{1,18}$'''),
      ('cambiar_regalo_promocion(bigint,bigint,bigint,boolean,jsonb)',
       E'       AND (id = ANY (v_comparte) OR id = ANY (v_actualiza))',
       E'       AND false /* MUTADO */ AND (id = ANY (v_comparte) OR id = ANY (v_actualiza))'),
      ('actualizar_precios_masivo(jsonb,jsonb)',
       E'      v_espera_ms := GREATEST(1, LEAST(1000,',
       E'      v_espera_ms := 60000 + 0 * GREATEST(1, LEAST(1000, /* MUTADO */')
    ) v(f, pat, rep)
  LOOP
    -- Las dos de cambiar_cliente_pedido van sobre el mismo cuerpo: se lee el vivo, no el guardado.
    d := pg_get_functiondef(f::regprocedure);
    IF (length(d) - length(replace(d, pat, ''))) / length(pat) <> 1 THEN
      RAISE EXCEPTION '%: el patrón no aparece una sola vez (¿falta la migración de la tarjeta 6?)', f;
    END IF;
    EXECUTE replace(d, pat, rep);
  END LOOP;
END
$m$;
GRANT UPDATE (producto_regalo_id, ajuste_producto_id) ON public.promociones TO authenticated;

-- ===== RESTAURAR (correr aparte, después de las variantes) =====
-- DO $r$ DECLARE d text; BEGIN FOR d IN SELECT def FROM conc.mut_orig LOOP EXECUTE d; END LOOP; END $r$; TRUNCATE conc.mut_orig;
-- REVOKE UPDATE (producto_regalo_id, ajuste_producto_id) ON public.promociones FROM authenticated;
