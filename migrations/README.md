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

## Permisos: el REVOKE necesita las DOS mitades

**`REVOKE ... FROM PUBLIC` a secas no cierra nada. `REVOKE ... FROM anon` a secas tampoco.**

Supabase trae un `ALTER DEFAULT PRIVILEGES` que le concede `EXECUTE` a `anon` de forma
**explícita** en cada función nueva, **además** del grant implícito a `PUBLIC` que pone
Postgres. El ACL de una función recién creada tiene las dos cosas:

```
{=X/postgres, postgres=X/postgres, anon=X/postgres, authenticated=X/postgres, service_role=X/postgres}
 ^^^^^^^^^^^^ esto es PUBLIC                ^^^^^^^^^^^^^^^^ y esto es el grant explícito
```

| Lo que escribís | Lo que queda | ¿anon ejecuta? |
| --- | --- | --- |
| `REVOKE ... FROM PUBLIC` | `anon=X/postgres` | **sí** |
| `REVOKE ... FROM anon` | `=X/postgres` | **sí**, por PUBLIC |
| `REVOKE ... FROM PUBLIC, anon` | — | no ✅ |

Esto rompió en silencio durante meses. La migración **089** dice textual
*«Solo lo llaman los wrappers DEFINER; no se expone a clientes»* y a continuación hace
`REVOKE ALL ... FROM PUBLIC`: la intención era correcta y el mecanismo la dejó pasar.
`_aplicar_cambio_producto` quedó alcanzable con la anon key, siendo `SECURITY DEFINER`,
sin gate propio y recibiendo `p_sucursal_id` / `p_usuario_id` por parámetro.

La **188** cerró todo lo existente y sacó `anon` del `ALTER DEFAULT PRIVILEGES`.

> **Lo que el default privilege NO puede hacer.** A `PUBLIC` no se lo puede sacar del default:
> `ALTER DEFAULT PRIVILEGES ... REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC` es un **no-op** (no crea
> fila en `pg_default_acl`, y cuando la fila existe el `acldefault()` built-in —que incluye
> `=X` para PUBLIC— se concatena igual). Medido sobre Postgres 17. O sea: **toda función nueva
> sigue naciendo con `=X/postgres`** y hay que revocárselo a mano.
>
> Lo que sí cambió: como ya no queda un `anon=X/postgres` atrás, escribir sólo
> `REVOKE ... FROM PUBLIC` **ahora sí** cierra a anon. El patrón que estaba roto en 40
> migraciones pasó a ser correcto. Igual conviene escribir las dos mitades: es idempotente y
> hace falta para las funciones viejas.
>
> La garantía de que esto no recaiga es el **gate de CI**, no el default privilege.

### La receta

```sql
REVOKE EXECUTE ON FUNCTION public.mi_rpc(bigint, date) FROM PUBLIC, anon;
GRANT  EXECUTE ON FUNCTION public.mi_rpc(bigint, date) TO authenticated;   -- la app web
-- GRANT  EXECUTE ON FUNCTION public.mi_rpc(bigint, date) TO service_role; -- bot / edge / scripts
```

Quién es quién: la web entra como **`authenticated`** (requiere login); el bot de Telegram,
las edge functions y `scripts/check-*.mjs` usan **`service_role`**. **`anon` no lo usa nadie**
— es el rol de la clave pública sin sesión.

### Trampas

- **`CREATE OR REPLACE` conserva el ACL; `DROP` + `CREATE` lo resetea.** Si cambiás la firma
  de una función (lo que obliga a dropear), **el hardening previo se pierde** y hay que
  reescribir el `REVOKE`/`GRANT`. `ALTER FUNCTION ... RENAME TO` también conserva el ACL
  (es lo que aprovechó la 167 con las `*_impl`).
- **Un `CREATE OR REPLACE` de `es_admin()` / `es_preventista()` / `current_sucursal_id()`
  revierte cambios de rol en silencio.** Ver la nota de la mig 155/156.
- **No revoques `authenticated` de los helpers de RLS** (`es_admin()`, `current_sucursal_id()`,
  `es_encargado_o_admin()`, …): las políticas RLS se evalúan como el usuario que consulta, así
  que necesita `EXECUTE`. Sacárselo rompe **todas** las queries, no una.
- **Las funciones de extensiones no se tocan** (`pg_trgm`, `unaccent`, `pgcrypto`). Filtralas
  con `pg_depend.deptype = 'e'` o vas a romper índices y operadores.
- **Las funciones trigger no necesitan `EXECUTE` para dispararse**: el permiso se chequea en
  `CREATE TRIGGER`, no cuando el trigger corre. Se les puede revocar todo (lo hicieron la 069
  y la 188).

### Convención de nombres (ahora con efecto real)

| Patrón | Significa | Permisos |
| --- | --- | --- |
| `_nombre` | helper interno; sólo lo llaman wrappers `SECURITY DEFINER` | nadie: ni `anon`, ni `authenticated` |
| `nombre_impl` | cuerpo real detrás de un wrapper (idempotencia, mig 167) | ídem |
| `RETURNS trigger` | lo dispara el motor | ídem |
| `bot_*` | las llama el bot | sólo `service_role` (excepto `bot_admin_*`, que las usa la web) |

La 188 barre por estos patrones, así que **una función nueva que se llame `_algo` queda
cerrada sola**. Si necesitás que la app la llame, no la nombres con guion bajo.

### Verificarlo

```bash
SUPABASE_URL=... SUPABASE_SERVICE_ROLE_KEY=... node scripts/check-permisos.mjs
```

Falla si alguna función de `public` volvió a quedar ejecutable por `anon`. Corre a diario en
`.github/workflows/integridad.yml`. Se apoya en el RPC `auditoria_permisos_execute()`
(mig 189), que además lista las `SECURITY DEFINER` sin gate propio alcanzables por
`authenticated` — el riesgo residual, informativo.

Para mirar el estado sin aplicar nada: `scripts/auditoria-permisos.sql` (sólo lee el catálogo).

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
