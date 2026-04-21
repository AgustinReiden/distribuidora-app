# Guía de Deploy

## Resumen

El código llega a producción en **Coolify** (Hostinger) automáticamente al mergear a `main` vía webhook, y opcionalmente se despliega a **Vercel** (staging) mediante un `workflow_dispatch` manual. Todo push o PR a `main`/`develop` dispara primero el workflow de CI (`.github/workflows/ci.yml`) con lint, typecheck, tests, auditoría de seguridad, build y E2E antes de cualquier deploy.

### Comandos rápidos

```bash
# Deploy manual a staging (Vercel)
gh workflow run deploy.yml -f environment=staging

# Re-disparar deploy a producción (Coolify) sobre el main actual
gh workflow run deploy.yml -f environment=production

# Ver estado del último run de deploy
gh run list --workflow=deploy.yml --limit 5

# Ver logs del último run del CI
gh run view --log
```

## Entornos

| Entorno | Plataforma | Trigger | URL | Vars de build |
|---------|-----------|---------|-----|---------------|
| Producción | Coolify (Docker + Nginx) | Push a `main` (webhook `COOLIFY_WEBHOOK_URL`) | Dominio productivo (Hostinger) | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN`, `VITE_GOOGLE_API_KEY`, `VITE_N8N_WEBHOOK_URL`, `VITE_N8N_FACTURA_WEBHOOK_URL`, `VITE_APP_VERSION`, `N8N_UPSTREAM` (runtime) |
| Staging | Vercel | `workflow_dispatch` manual con `environment=staging` | Preview URL Vercel | `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_ANON_KEY`, `SENTRY_DSN` (secret GitHub) → `VITE_SENTRY_DSN` (env de build), `VITE_GOOGLE_API_KEY`, `VITE_N8N_WEBHOOK_URL`, `VITE_N8N_FACTURA_WEBHOOK_URL` |
| Local | Vite dev server | `npm run dev` | `http://localhost:5173` | `.env` local (ver `.env.example`) |

## Flujo de Deploy a Producción

Cuando se mergea un PR a `main`:

1. **CI (`.github/workflows/ci.yml`)** corre en el push a `main`:
   - `lint` - ESLint
   - `typecheck` - TypeScript
   - `test` - Vitest (unit + coverage)
   - `security` - `npm audit --audit-level=high` + `npm run check-secrets`
   - `build` - depende de `lint`, `test`, `typecheck`, `security`
   - `e2e` - Playwright (Chromium), depende de `build`
2. **Deploy (`.github/workflows/deploy.yml`)**: el job `deploy-coolify` corre en paralelo al CI en cada push a `main`. El job `deploy-staging` **solo** corre con `workflow_dispatch` manual con `environment=staging` (ver sección de staging), no en el push a `main`.
   - Job `deploy-coolify` dispara `POST` al `COOLIFY_WEBHOOK_URL` (timeout 30s).
   - Coolify hace `git pull` del repo y construye el `Dockerfile` (Node 20-alpine → Nginx 1.27-alpine, multi-stage).
   - El contenedor tiene un `HEALTHCHECK` cada 30s (`wget http://localhost/`), con `start-period=5s` y 3 reintentos.
3. Coolify levanta el nuevo contenedor; Nginx sirve `/usr/share/nginx/html` y proxy-pasea `/api/n8n/` al `N8N_UPSTREAM` configurado en runtime.

> Nota: CI y deploy son workflows separados. El deploy a Coolify **no espera** a que CI termine; si CI falla después de mergear, hay que revertir manualmente (ver `docs/ROLLBACK.md`). La branch protection (abajo) es lo que evita que llegue código sin CI verde a `main`.

### Timing esperado

| Paso | Duración típica |
|------|-----------------|
| CI completo (lint + typecheck + test + security + build + e2e) | 6-10 min |
| Webhook Coolify → nuevo contenedor `healthy` | 2-4 min |
| Service worker hereda bundle nuevo en clientes activos | Siguiente reload completo |

Si algún paso se dispara al doble de ese tiempo sin avanzar, revisar Actions y los logs de Coolify.

## Deploy a Staging

Staging es manual. Desde la terminal (requiere `gh` autenticado):

```bash
gh workflow run deploy.yml -f environment=staging
```

O desde la UI: **Actions → Deploy → Run workflow → environment: staging**.

El job `deploy-staging`:
1. Instala dependencias (`npm ci`).
2. Corre `npm run test:run`.
3. Buildea con los secrets `STAGING_SUPABASE_URL` / `STAGING_SUPABASE_ANON_KEY` (apunta a un proyecto Supabase distinto al de producción).
4. Sube a Vercel con `amondnet/vercel-action@v25` (requiere `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`).
5. Si el deploy falla, sube el `dist/` como artifact `staging-build-<sha>` (retención 30 días) para deploy manual.

### Re-deploy manual a producción

Si el webhook de Coolify no se disparó (por ejemplo falla transitoria):

```bash
gh workflow run deploy.yml -f environment=production
```

Esto vuelve a correr `deploy-coolify` sobre el `main` actual.

## Branch Protection Policy

**Estado actual:** debe configurarse manualmente en GitHub. Esta guía documenta el target.

Ir a **Settings → Branches → Add branch protection rule** (o editar la existente) para `main` y activar:

- [x] **Require a pull request before merging**
  - [ ] Require approvals: **desactivado** (o `0`). Activarlo en un repo de un solo desarrollador bloquea el merge porque GitHub no permite auto-aprobarse. Si en el futuro se suma otro dev con permiso de write, cambiar a `1` y activar "Dismiss stale pull request approvals when new commits are pushed".
- [x] **Require status checks to pass before merging**
  - [x] **Require branches to be up to date before merging**
  - Status checks requeridos (nombres exactos de los jobs de `ci.yml`):
    - `Lint`
    - `TypeScript Check`
    - `Unit Tests`
    - `Security Audit`
    - `Build`
    - `E2E Tests`
- [x] **Require conversation resolution before merging**
- [x] **Do not allow bypassing the above settings** (aplica también a admins)
- [ ] Allow force pushes: **desactivado**
- [ ] Allow deletions: **desactivado**

> Los nombres de los status checks deben coincidir con el `name:` de cada job, no con el `id`. Si se renombra un job en `ci.yml`, hay que actualizar el nombre acá o el PR quedará bloqueado esperando un check que no existe.

## Variables de Entorno Críticas

Fuente: `.env.example` para las `VITE_*` (build-time). `N8N_UPSTREAM` es runtime-only y solo se configura en Coolify (no está en `.env.example`). Todas las `VITE_*` quedan horneadas en el bundle en build-time (Vite las reemplaza como strings estáticos) — **nunca poner secretos reales** en variables `VITE_*`.

| Variable | Requerido | Descripción |
|----------|-----------|-------------|
| `VITE_SUPABASE_URL` | Sí | URL del proyecto Supabase (`https://<ref>.supabase.co`). |
| `VITE_SUPABASE_ANON_KEY` | Sí | Clave anon pública de Supabase. RLS protege los datos; no es un secreto. |
| `VITE_GOOGLE_API_KEY` | No | Google Routes API key para optimización de rutas en cliente. Preferiblemente usar n8n en backend. |
| `VITE_N8N_WEBHOOK_URL` | Sí | Ruta al webhook de optimización de ruta. En prod: `/api/n8n/webhook/optimizar-ruta` (proxy nginx). |
| `VITE_N8N_FACTURA_WEBHOOK_URL` | Sí | Ruta al webhook de escaneo de factura. En prod: `/api/n8n/webhook/escanear-factura`. |
| `VITE_SENTRY_DSN` | Recomendado | DSN de Sentry para reportar errores de producción. Vacío desactiva Sentry. |
| `VITE_APP_VERSION` | Recomendado | Versión de la app para releases de Sentry. En staging (job `deploy-staging`) el workflow pasa `${{ github.sha }}`. En producción (Coolify) se configura como env var en el dashboard de Coolify y se pasa como `ARG` al build del Dockerfile; el `ARG VITE_APP_VERSION` del Dockerfile no define default, así que si no se setea queda vacío. |
| `N8N_UPSTREAM` | Sí (solo Coolify) | URL base del n8n upstream (ej. `https://n8n.shycia.com.ar`). Runtime-only, usada por `envsubst` en el CMD del Dockerfile. |

### Dónde se configuran

- **Coolify:** Environment Variables del servicio (se pasan como `ARG` al build del Dockerfile, excepto `N8N_UPSTREAM` que va como `ENV` runtime).
- **Vercel:** Project Settings → Environment Variables, o como secrets del workflow (`STAGING_*`).
- **GitHub Actions secrets:** `Settings → Secrets and variables → Actions`. Requeridos: `COOLIFY_WEBHOOK_URL`, `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `STAGING_SUPABASE_URL`, `STAGING_SUPABASE_ANON_KEY`, `SENTRY_DSN`, `VERCEL_TOKEN`, `VERCEL_ORG_ID`, `VERCEL_PROJECT_ID`, `VITE_GOOGLE_API_KEY`, `VITE_N8N_WEBHOOK_URL`, `VITE_N8N_FACTURA_WEBHOOK_URL`.

## Monitoreo Post-Deploy

### Automático

- **Sentry:** dashboard del proyecto muestra errores nuevos y release health por `VITE_APP_VERSION`. Buscar picos de error rate en los primeros 15 minutos del deploy.
- **Coolify healthcheck:** `wget http://localhost/` cada 30s dentro del contenedor. Si falla 3 veces, el contenedor queda `unhealthy`.

### Checklist manual (smoke test, ~2 minutos)

Correr inmediatamente después de que Coolify reporte deploy exitoso:

- [ ] Login con usuario de prueba funciona.
- [ ] Vista de pedidos carga sin errores en consola.
- [ ] Crear pedido nuevo → guarda → aparece en la lista.
- [ ] Editar un pedido existente → persiste el cambio.
- [ ] Toggle de modo offline → la app sigue usable con datos cacheados.
- [ ] Service worker activo (DevTools → Application → Service Workers).
- [ ] Sin errores 4xx/5xx en la pestaña Network al navegar las vistas principales.

## Si algo falla

Ver **[`docs/ROLLBACK.md`](./ROLLBACK.md)** para el procedimiento de reversión (revert del commit, re-deploy manual, rollback de migraciones Supabase si aplica).

Síntomas que justifican rollback inmediato:
- Error rate en Sentry > 5× el baseline tras el deploy.
- Login quebrado o pedidos no se guardan.
- Healthcheck de Coolify falla de forma sostenida.
- 5xx masivos en Nginx.
