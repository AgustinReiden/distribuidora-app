-- La alerta "Clientes que dejaron de comprar" no cuenta a los dados de baja
--
-- EL PROBLEMA
-- -----------
-- `reporte_gerencial` arma la alerta `clientes_inactivos` (y
-- `reporte_alerta_detalle` su lista) con los clientes cuya ultima compra fue
-- hace 30 a 90 dias. Lo calcula sobre `pedidos` y nunca mira `clientes.activo`,
-- asi que un cliente que el admin dio de baja aparece como "dejo de comprar"
-- para siempre (hasta que se le pasen los 90 dias): justo el que ya se sabe que
-- no va a volver. Al aplicar esta migracion eran 2 de los 4 dados de baja.
--
-- Esa alerta es operativa —"a quien hay que ir a buscar"—, no historial. El
-- resto del tablero ya lo filtraba (`tablero_clientes_inactivos`,
-- `clientes_ritmo_compra`, `tablero_kpis`). Las ventas, la cobranza y la cuenta
-- corriente siguen viendo a los inactivos a proposito: es de lo que se trata la
-- baja logica (CLAUDE.md, "Toda lectura nueva de clientes decide...").
--
-- EL CAMBIO
-- ---------
-- El HAVING de las dos consultas suma la condicion de que el cliente siga
-- activo. En `reporte_gerencial` no hay join a clientes, asi que va por
-- `p.cliente_id IN (...)`; en `reporte_alerta_detalle` el join ya esta y alcanza
-- con `bool_and(c.activo)` (activo es NOT NULL).
--
-- PARCHE SOBRE EL BODY VIVO, como la 209: `reporte_gerencial` son 24.000
-- caracteres y cambia una linea. Si el ancla no aparece exactamente una vez en
-- cada funcion, aborta. Reaplicada, no hace nada. CREATE OR REPLACE con la
-- misma firma: preserva los ACL (authenticated=X, anon afuera) y no crea
-- sobrecargas.

BEGIN;

DO $patch$
DECLARE
  v_viejo text := 'HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90';
  v_cambios jsonb := jsonb_build_object(
    'reporte_gerencial',
      'HAVING MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90'
      || E'\n       AND p.cliente_id IN (SELECT id FROM clientes WHERE activo)  -- 388: la baja no "dejo de comprar"',
    'reporte_alerta_detalle',
      'HAVING bool_and(c.activo)  -- 388: la baja no "dejo de comprar"'
      || E'\n         AND MAX(p.fecha) < CURRENT_DATE - 30 AND MAX(p.fecha) >= CURRENT_DATE - 90'
  );
  v_fn    text;
  v_nuevo text;
  v_src   text;
  v_ocurr int;
BEGIN
  FOR v_fn, v_nuevo IN SELECT key, value FROM jsonb_each_text(v_cambios) LOOP
    SELECT pg_get_functiondef(p.oid) INTO v_src
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = v_fn;

    IF v_src IS NULL THEN
      RAISE EXCEPTION 'No existe public.%', v_fn;
    END IF;

    IF position('388: la baja no "dejo de comprar"' in v_src) > 0 THEN
      RAISE NOTICE '% ya excluye a los dados de baja, no se toca', v_fn;
      CONTINUE;
    END IF;

    v_ocurr := (length(v_src) - length(replace(v_src, v_viejo, ''))) / length(v_viejo);
    IF v_ocurr <> 1 THEN
      RAISE EXCEPTION 'Se esperaba 1 ocurrencia del HAVING de clientes_inactivos en % y hay %. '
        'Mira el body actual y ajusta el ancla.', v_fn, v_ocurr;
    END IF;

    EXECUTE replace(v_src, v_viejo, v_nuevo);
  END LOOP;
END
$patch$;

COMMIT;
