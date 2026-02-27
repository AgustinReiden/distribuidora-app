-- 030: Add auto-generated unique 'codigo' to clientes
-- Each client gets a sequential code for easy identification

CREATE SEQUENCE IF NOT EXISTS clientes_codigo_seq;
ALTER TABLE clientes ADD COLUMN IF NOT EXISTS codigo INTEGER;

-- Backfill existing clients in creation order
WITH ordered AS (
  SELECT id, ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) AS rn FROM clientes
)
UPDATE clientes SET codigo = ordered.rn FROM ordered WHERE clientes.id = ordered.id;

-- Set sequence to continue after the highest assigned code
SELECT setval('clientes_codigo_seq', COALESCE((SELECT MAX(codigo) FROM clientes), 0));

-- Make codigo required with auto-increment default and unique constraint
ALTER TABLE clientes
  ALTER COLUMN codigo SET DEFAULT nextval('clientes_codigo_seq'),
  ALTER COLUMN codigo SET NOT NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'clientes_codigo_unique'
  ) THEN
    ALTER TABLE clientes ADD CONSTRAINT clientes_codigo_unique UNIQUE (codigo);
  END IF;
END $$;
