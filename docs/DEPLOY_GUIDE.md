# Guía de Deploy

## Resumen

El código llega a producción en **Coolify** (Hostinger) automáticamente al mergear a `main`: Coolify recibe el push por su integración con GitHub y reconstruye. No hay workflow de deploy en el repo. El CI (`.github/workflows/ci.yml`) corre en cada PR, y la branch protection de `main` exige que esté verde antes de mergear.

### Comandos rápidos

```bash
# Ver logs del último run del CI
gh run view --log

# Verificar qué build está sirviendo producción (cambia en cada deploy)
curl -sI https://crecer.shycia.com.ar/ | grep -i last-modified
```

Re-deploy manual: panel de Coolify → la app → **Redeploy**.

## Entornos

| Entorno | Plataforma | Trigger | URL | Vars de build |
|---------|-----------|---------|-----|---------------|
| Producción | Coolify (Docker + Nginx) | Push a `main` (integración de Coolify con GitHub) | Dominio productivo (Hostinger) | `VITE_SUPABASE_URL`, `VITE_SUPABASE_ANON_KEY`, `VITE_SENTRY_DSN`, `VITE_GOOGLE_API_KEY`, `VITE_APP_VERSION`, `N8N_UPSTREAM` (runtime) |
| Local | Vite dev server | `npm run dev` | `http://localhost:5173` | `.env` local (ver `.env.example`) |

## Flujo de Deploy a Producción

Cuando se mergea un PR a `main`:

1. **Antes del merge**, el CI (`.github/workflows/ci.yml`) ya corrió sobre el PR y la branch protection exige que esté verde y la rama al día con `main`:
   - `lint` - ESLint
   - `typecheck` - TypeScript
   - `test` - Vitest (unit + coverage)
   - `security` - `npm audit --audit-level=high` + `npm run check-secrets`
   - `build` - depende de `lint`, `test`, `typecheck`, `security`
   - `e2e` - Playwright (Chromium), depende de `build`
2. **El push a `main`** lo recibe Coolify por su integración con GitHub:
   - Coolify hace `git pull` del repo y construye el `Dockerfile` (Node 20-alpine → Nginx 1.27-alpine, multi-stage). El build corre `npm run build:strict` (`tsc --noEmit` + `vite build`).
   - El contenedor tiene un `HEALTHCHECK` cada 30s (`wget http://localhost/`), con `start-period=5s` y 3 reintentos.
3. Coolify levanta el nuevo contenedor; Nginx sirve `/usr/share/nginx/html` y proxy-pasea `/api/n8n/` al `N8N_UPSTREAM` configurado en runtime.

> Nota: Coolify **no espera** al CI del push a `main`: deploya en cuanto llega el push. Lo que evita que llegue a producción código sin CI verde es la branch protection (abajo), que obliga a pasar por PR con los checks en verde, también a los admins. En un repo privado con GitHub Free la branch protection no rige, y entonces no queda nada entre un push y producción.

### Timing esperado

| Paso | Duración típica |
|------|-----------------|
| CI completo (lint + typecheck + test + security + build + e2e) | ~10 min |
| Push a `main` → nuevo contenedor `healthy` | 2-4 min |
| Service worker hereda bundle nuevo en clientes activos | Siguiente reload completo |

Si algún paso se dispara al doble de ese tiempo sin avanzar, revisar Actions y los logs de Coolify.

### Re-deploy manual a producción

Si Coolify no tomó el push (por ejemplo una falla transitoria): panel de Coolify → la app → **Redeploy** sobre el `main` actual. Se verifica con el `Last-Modified` de los comandos rápidos.

## Branch Protection Policy

**Estado actual:** configurada. Es el único gate entre el código y producción (ver la nota del flujo de deploy).

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
    - `Embeds de PostgREST`
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
| `VITE_GOOGLE_API_KEY` | Sí | Key del SDK de Google Maps (autocompletado de direcciones, geocoding inverso). Viaja en el bundle porque el SDK se carga con `<script src="...?key=">`: es pública por diseño y se protege con restricciones de referrer HTTP en Google Cloud Console. **No** la usa la optimización de rutas — eso va por la Edge Function `optimizar-ruta`, que tiene su propia key como secret del servidor. |
| `VITE_CARTO_API_KEY` | Recomendado | Key de mosaicos CARTO del mapa Leaflet (`MapaRuta`). Pública por diseño, restringida por referer al dominio de prod en el panel de CARTO; localhost usa una key aparte. Sin setear, el mapa cae a OpenStreetMap (sin la key, CARTO devuelve los mosaicos con la marca "API KEY REQUIRED"). |
| `VITE_SENTRY_DSN` | Recomendado | DSN de Sentry para reportar errores de producción. Vacío desactiva Sentry. |
| `VITE_APP_VERSION` | Recomendado | Versión de la app para releases de Sentry. En producción (Coolify) se configura como env var en el dashboard de Coolify y se pasa como `ARG` al build del Dockerfile; el `ARG VITE_APP_VERSION` del Dockerfile no define default, así que si no se setea queda vacío. |
| `N8N_UPSTREAM` | Sí (solo Coolify) | URL base del n8n upstream (ej. `https://n8n.shycia.com.ar`). Runtime-only, usada por `envsubst` en el CMD del Dockerfile. |

### Dónde se configuran

- **Coolify:** Environment Variables del servicio, marcadas como variables de build (se pasan como `ARG` al build del Dockerfile), excepto `N8N_UPSTREAM` que va como `ENV` runtime. Cambiar una `VITE_*` requiere **Redeploy** (rebuild), no Restart.
- **GitHub Actions secrets:** el deploy del front no usa ninguno. Los que hay son del CI, los crons y las edge functions (Supabase, Telegram, backup, LLMs).

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
