-- =========================================================================
-- 163_backfill_marcas_por_nombre.sql
--
-- La mig 158 sólo pudo backfillear las marcas de la sucursal 1 que estaban
-- cargadas como categorías. Quedaron 137 productos sin marca — 92 en Taco
-- Pozo, donde la marca vive dentro del nombre del producto.
--
-- Este backfill asigna SÓLO los casos donde la marca es inequívoca en el
-- nombre. Se dejan a propósito sin marca los que requieren criterio comercial:
--   · "PAPAS FRITAS 200GRS", "CHIZITOS", "PUFLITO", "NACHO LIBRE"  → sin marca en el nombre
--   · "AZUCAR CALIDAD", "AZUCAR INDEPENDENCIA"                     → ¿marca o descriptor?
--   · "VINO TORO TETRA", "VINO VIÑA DE BALBO"                      → hay marca, pero no sé si
--                                                                     se quieren separadas
--   · "AGUA EL SANO CORAZON ARGENTINO"                             → ¿"EL SANO"? ambiguo
--   · "SAL FINA", "FERNET 750ML", "CEPILLO DE DIENTES NIÑO"        → sin marca
-- Esos 40 y pico se asignan a mano desde Productos → Catálogo → Marcas.
--
-- ORDEN IMPORTANTE: VILLAMANAOS se resuelve ANTES que MANAOS. "AGUA VILLA
-- MANAOS CON GAS" contiene "MANAOS" pero es otra marca; al revés quedaría mal
-- clasificada y el error sería invisible.
--
-- Sólo se tocan productos con marca_id NULL: re-aplicar no pisa correcciones
-- hechas a mano desde la UI.
-- =========================================================================

DO $$
DECLARE
  r          RECORD;
  v_marca_id uuid;
  v_n        integer;
  -- patron: regex sobre upper(nombre). El orden de esta lista ES la precedencia.
  v_reglas CONSTANT jsonb := '[
    {"marca": "VILLAMANAOS",  "patron": "VILLA ?MANAOS"},
    {"marca": "MANAOS",       "patron": "^MANAOS\\M"},
    {"marca": "PLACER",       "patron": "^PLACER\\M"},
    {"marca": "PINDAPOY",     "patron": "\\mPINDAPOY\\M"},
    {"marca": "COTELLA",      "patron": "\\mCOTELLA\\M"},
    {"marca": "RICATTO",      "patron": "\\mRICATTO\\M"},
    {"marca": "RIVOLLI",      "patron": "\\mRIVOLLI\\M"},
    {"marca": "MONDEO",       "patron": "\\mMONDEO\\M"},
    {"marca": "NESS",         "patron": "\\mNESS\\M"},
    {"marca": "NATUREZA",     "patron": "\\mNATUREZA\\M"},
    {"marca": "ALFATUC",      "patron": "\\mALFATUC\\M"},
    {"marca": "COCA COLA",    "patron": "\\mCOCA COLA\\M"},
    {"marca": "PANINI",       "patron": "\\mPANINI\\M"}
  ]'::jsonb;
  v_suc bigint;
BEGIN
  FOREACH v_suc IN ARRAY ARRAY[1::bigint, 2::bigint]
  LOOP
    FOR r IN SELECT * FROM jsonb_to_recordset(v_reglas) AS x(marca text, patron text)
    LOOP
      -- ¿Hay algún producto sin marca que matchee en esta sucursal? Si no, no
      -- se crea la marca: mejor no ensuciar el ABM con marcas vacías.
      SELECT count(*) INTO v_n
      FROM productos p
      WHERE p.sucursal_id = v_suc AND p.marca_id IS NULL
        AND upper(p.nombre) ~ r.patron;

      IF v_n = 0 THEN
        CONTINUE;
      END IF;

      INSERT INTO marcas (nombre, sucursal_id)
      VALUES (r.marca, v_suc)
      ON CONFLICT (sucursal_id, nombre) DO NOTHING;

      SELECT id INTO v_marca_id FROM marcas
      WHERE sucursal_id = v_suc AND nombre = r.marca;

      UPDATE productos p
      SET marca_id = v_marca_id
      WHERE p.sucursal_id = v_suc
        AND p.marca_id IS NULL          -- la precedencia de la lista se sostiene acá
        AND upper(p.nombre) ~ r.patron;

      RAISE NOTICE 'Sucursal %: % productos → %', v_suc, v_n, r.marca;
    END LOOP;
  END LOOP;
END $$;
