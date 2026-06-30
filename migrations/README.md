# Migraciones

## ⚠️ Antes que nada: la fuente de verdad es PRODUCCIÓN

Esta carpeta es una **vista curada y consolidada** del historial, **NO un espejo 1:1** de lo
que está aplicado. La verdad vive en el ledger de prod
(`supabase_migrations.schema_migrations`). **`migrations/MANIFEST.md`** mapea repo ↔ prod y
lista todas las divergencias conocidas (duplicados, consolidaciones, out-of-band, offsets).

**Antes de asumir que algo falta o está pendiente, verificá en vivo:**

- **Agente con MCP de Supabase:** `list_migrations` y comparar con `ls migrations/`.
- **CI / humano:** `npm run check:migrations` (`scripts/check-migrations.mjs`) — falla si hay
  drift por encima del snapshot reconciliado. Requiere `SUPABASE_URL` + `SUPABASE_SERVICE_ROLE_KEY`.
  Corre también a diario en `.github/workflows/integridad.yml`.

## Estado actual

- **`000_baseline.sql`** — dump fiel del schema `public` de prod **ManaosApp**
  (`hmuchlzmuqqxcldbzkgc`), generado con `supabase db dump` el **2026-04-21**.
  - 39 tablas + 3 vistas, 73 funciones RPC, 115 políticas RLS, 5 extensiones.
  - Es el punto de partida del schema **al 2026-04-21**. Todo lo previo está consolidado aquí.
- **`001…NNN_*.sql`** — cambios post-baseline, numerados correlativos. Ver `MANIFEST.md` para el
  mapeo exacto contra el ledger (algunos archivos consolidan varias filas, renombran o renumeran).
- **`archive/`** — historial pre-baseline (001–070 + hotfixes). **No aplicar.** Solo registro.

## Convención para nuevas migraciones

1. Crear `migrations/NNN_descripcion.sql` (idempotente cuando sea razonable:
   `CREATE TABLE IF NOT EXISTS`, `DROP … IF EXISTS` / `CREATE OR REPLACE`, `ON CONFLICT …`).
2. **Aplicar a prod** y que quede registrado en el ledger con el **mismo nombre**:
   - **Recomendado — MCP de Supabase:** `apply_migration(name = "NNN_descripcion", query = …)`.
     Queda en `schema_migrations` automáticamente. Es como se aplica hoy.
   - SQL editor del dashboard, o CLI:
     ```bash
     npx supabase db push --db-url "postgresql://postgres.hmuchlzmuqqxcldbzkgc:<password>@aws-1-sa-east-1.pooler.supabase.com:5432/postgres"
     ```
     > Si aplicás por SQL editor/`execute_sql`, **NO** queda en el ledger ("out-of-band"):
     > registralo después (`INSERT` en `schema_migrations`) y anotalo en `MANIFEST.md §C`.

Mantener archivo y `name` del ledger **alineados** evita que `check:migrations` marque drift y
que el MANIFEST tenga que documentar la excepción.

Proyecto: `hmuchlzmuqqxcldbzkgc` (región `sa-east-1`, Postgres 17.6.1).

## Regenerar el baseline

Si el schema de prod cambia mucho fuera de banda y conviene re-sincronizar el punto de partida:

```bash
npx supabase db dump \
  --db-url "postgresql://postgres.hmuchlzmuqqxcldbzkgc:<password>@aws-1-sa-east-1.pooler.supabase.com:5432/postgres" \
  --schema public \
  -f migrations/000_baseline.sql
```

Después: preservar el header de `000_baseline.sql` (líneas 1–7), actualizar la **fecha** acá y
en `MANIFEST.md`, y mover los `NNN_*.sql` ya consolidados a `archive/`.
