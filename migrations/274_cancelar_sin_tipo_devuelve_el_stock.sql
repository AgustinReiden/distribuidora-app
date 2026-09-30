-- Cancelar sin tipo devuelve el stock (hotfix de la 269, #827)
--
-- La 269 declaro `v_falta_stock BOOLEAN := (p_tipo = 'falta_stock')`. Con
-- p_tipo NULL eso es NULL, `IF NOT v_falta_stock` no entra, y la cancelacion
-- caia en la rama de falta de stock: mermaba en vez de devolver. Afecta a toda
-- cancelacion sin tipo (y a cambiar_cliente_pedido si llama sin tipo). Entre la
-- 269 y esta no hubo cancelaciones ni mermas en prod: no hay datos que reparar.
DO $mig$
DECLARE v_def TEXT; v_new TEXT;
BEGIN
  v_def := pg_get_functiondef('public.cancelar_pedido_con_stock'::regproc);
  v_new := replace(v_def,
    $a$v_falta_stock BOOLEAN := (p_tipo = 'falta_stock');$a$,
    $b$v_falta_stock BOOLEAN := COALESCE(p_tipo = 'falta_stock', false);  -- mig 274: NULL no es falta de stock$b$);
  IF v_new = v_def THEN RAISE EXCEPTION 'no se encontro la declaracion de v_falta_stock'; END IF;
  EXECUTE v_new;
END
$mig$;
