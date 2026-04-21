# Migraciones

## Estado actual

- **`000_baseline.sql`** — dump fiel del schema `public` de la DB de producción **ManaosApp** (`hmuchlzmuqqxcldbzkgc`), generado con `supabase db dump` el 2026-04-21.
  - 39 tablas + 3 vistas, 73 funciones RPC, 115 políticas RLS, 5 extensiones.
  - Es la única fuente de verdad para el schema. Todo lo previo está consolidado aquí.
- **`archive/`** — historial consolidado (001–070 + hotfixes datados). **No aplicar.** Solo queda como registro histórico consultable.

## Convención para nuevas migraciones

Los próximos cambios van como `001_descripcion.sql`, `002_…`, numerados correlativos después del baseline. Cada archivo debe ser idempotente cuando sea razonable (ej.: `CREATE TABLE IF NOT EXISTS`, `DROP FUNCTION IF EXISTS` antes de recrear).

**Aplicar manualmente** vía el SQL Editor de Supabase, o vía CLI:

```bash
npx supabase db push --db-url "postgresql://postgres.hmuchlzmuqqxcldbzkgc:<password>@aws-1-sa-east-1.pooler.supabase.com:5432/postgres"
```

Proyecto: `hmuchlzmuqqxcldbzkgc` (región `sa-east-1`, Postgres 17.6.1).

## Regenerar el baseline

Si el schema de prod cambia fuera de banda y hay que re-sincronizar:

```bash
npx supabase db dump \
  --db-url "postgresql://postgres.hmuchlzmuqqxcldbzkgc:<password>@aws-1-sa-east-1.pooler.supabase.com:5432/postgres" \
  --schema public \
  -f migrations/000_baseline.sql
```

Preservar el header de `000_baseline.sql` (líneas 1–7) después de regenerar.
