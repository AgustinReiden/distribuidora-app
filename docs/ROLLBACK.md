# Rollback de Producción (Coolify)

Runbook corto para revertir producción cuando un deploy rompe algo. Complementa a [`docs/DEPLOY_GUIDE.md`](./DEPLOY_GUIDE.md).

## Comandos rápidos (copy-paste)

```bash
# 1. Revert del commit problemático (en main, con el hash a revertir)
git revert <commit-hash>    # si es merge commit, agregá: -m 1
git push origin main

# 2. Si el revert no basta y hay que re-disparar el webhook de Coolify
gh workflow run deploy.yml -f environment=production

# 3. Verificar que el nuevo run se disparó
gh run list --workflow=deploy.yml --limit 3
```

- Sentry: abrir dashboard del proyecto y filtrar por "Last 15 minutes" (ver `VITE_SENTRY_DSN` en `.env` o en Environment Variables de Coolify; más detalle en [`docs/DEPLOY_GUIDE.md`](./DEPLOY_GUIDE.md)).

## Cuándo usar

Disparar rollback si ocurre alguno de estos síntomas post-deploy:

- Error rate en Sentry > 5× el baseline en los primeros 15 minutos.
- Login quebrado, o crear/editar pedidos tira error.
- Healthcheck de Coolify falla de forma sostenida (contenedor `unhealthy`).
- 5xx masivos en Nginx o usuario reporta ruptura de un flujo clave (pedidos, rutas, factura).

Si dudás, rollback. Es más barato revertir y re-investigar que dejar prod rota.

## Pasos (< 5 min)

### Opción A: Revert via Git (preferido)

Esta es la ruta por defecto. Deja historial auditable y vuelve a pasar por CI.

1. Identificar el commit problemático en `main` (`git log --oneline -10`).
2. En una working copy limpia de `main`:
   ```bash
   git checkout main
   git pull origin main
   git revert <commit-hash>    # si es merge commit, agregá: -m 1
   git push origin main
   ```
3. El push a `main` dispara el webhook de Coolify automáticamente (`deploy-coolify` en `.github/workflows/deploy.yml`).
4. Esperar 2-4 min a que Coolify levante el contenedor nuevo con `HEALTHCHECK` verde.

### Opción B: Re-disparar deploy manual en Coolify

Usar si el revert en git ya se pusheó pero el webhook no se disparó, o si querés forzar un rebuild sobre el `main` actual sin commit nuevo.

Desde terminal:

```bash
gh workflow run deploy.yml -f environment=production
```

O desde la UI de GitHub: **Actions → Deploy → Run workflow → environment: production**.

Alternativa directa en Coolify: **Dashboard → App de Distribuidora → Redeploy** sobre el último deployment verde conocido. Esperar healthcheck (~2-3 min).

## Rollback de DB (migración Supabase)

Las migraciones están en `migrations/` (ver [`migrations/README.md`](../migrations/README.md)). El scheme actual es:

- `000_baseline.sql` — dump fiel del schema de prod. No se re-ejecuta.
- Migraciones nuevas numeradas `001_...`, `002_...`, aplicadas **manualmente** vía SQL Editor de Supabase o `npx supabase db push`.

**No hay mecanismo de revert automático en el repo.** Supabase tampoco tiene "undo migration" built-in desde el CLI. Opciones:

1. **Migración inversa manual** (preferido si el cambio es chico): escribir un `NNN_revert_<cosa>.sql` con el `DROP` / `ALTER` opuesto y aplicarlo vía SQL Editor. Commitearlo al repo para dejar registro.
2. **Point-in-time recovery (PITR) de Supabase**: solo disponible en el plan Pro+. Requiere dashboard de Supabase → Database → Backups → PITR. Restaura la DB entera a un timestamp — **destructivo para datos escritos después**. Último recurso.
3. **Backup manual previo**: si se anticipaba riesgo, debería haberse corrido un `pg_dump` antes. Ver [`docs/RLS_MIGRATION_GUIDE.md`](./RLS_MIGRATION_GUIDE.md) que menciona "Backup de la base de datos (recomendado)" como pre-requisito.

Si el rollback de código (Opción A arriba) ya resolvió el síntoma y la migración no rompe por sí misma, **dejá la migración aplicada** y seguí. Revertir DDL innecesariamente introduce más riesgo.

## Validación post-rollback

Correr este checklist no bien Coolify reporte healthy el contenedor nuevo:

- [ ] Sentry: sin errores nuevos en los últimos 5 min (filtro por release = versión revertida).
- [ ] Login manual con cuenta de testing funciona.
- [ ] Vista de pedidos carga sin errores en consola del browser.
- [ ] Crear pedido + guardar → aparece en la lista.
- [ ] Editar un pedido existente → persiste.
- [ ] Toggle de modo offline → app sigue usable, operación queda queueada.
- [ ] Service worker activo (DevTools → Application → Service Workers).
- [ ] Sin 4xx/5xx en Network en las vistas principales.

Si algún paso falla, NO seguir con el día. Escalar.

## Qué NO hacer

- **No hacer `git push --force` a `main`.** La branch protection debería bloquearlo, pero igual — reescribir historia de prod rompe a todos los colaboradores y deja Coolify en estado indefinido.
- **No hacer `git reset --hard` sobre `main` local y pushear.** Mismo problema que el anterior. Usar `git revert`, que es aditivo.
- **No borrar el deployment anterior en Coolify** hasta haber validado el rollback en vivo. Lo necesitás como vuelta atrás de la vuelta atrás.
- **No tocar la DB de producción** (`DROP`, `DELETE` masivos, `TRUNCATE`) sin backup previo y sin un segundo par de ojos.
- **No saltarse el CI** con `[skip ci]` en el commit del revert. Queremos que el revert pase por lint + typecheck + tests como cualquier cambio.
- **No deployar fix-forward a las apuradas** si no estás seguro del diagnóstico. Primero revert, después investigás con calma.

## Referencias

- [`docs/DEPLOY_GUIDE.md`](./DEPLOY_GUIDE.md) — flujo de deploy, entornos y variables.
- [`migrations/README.md`](../migrations/README.md) — scheme de migraciones Supabase.
- [`docs/RLS_MIGRATION_GUIDE.md`](./RLS_MIGRATION_GUIDE.md) — políticas RLS y pre-requisitos de backup.
- `.github/workflows/deploy.yml` — job `deploy-coolify` y trigger del webhook.

## Contactos

- Responsable técnico: Agustín Reiden (`<email en contacto interno>`).
- Dashboard Supabase: https://supabase.com/dashboard/project/hmuchlzmuqqxcldbzkgc
- Dashboard Coolify: `<ver link interno / panel de Hostinger>`.
- Sentry: `<ver VITE_SENTRY_DSN en .env o en Environment Variables de Coolify>`.
