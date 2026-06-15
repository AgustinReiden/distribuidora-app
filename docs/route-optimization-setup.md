# Optimización de rutas 40+ — Google Route Optimization API (setup)

La edge function `optimizar-ruta` usa **dos motores**:

1. **Google Route Optimization API** (`optimizeTours`) — óptimo global de 100+ paradas en una sola llamada. Se usa **si está cargado el secret `GOOGLE_SA_KEY`**. Es lo que arregla el zigzag para rutas de 40+ pedidos.
2. **Fallback: Routes API `computeRoutes`** (secret `GOOGLE_API_KEY`) — parte en tramos de ≤23. Se usa si no hay `GOOGLE_SA_KEY` o si Route Optimization falla. Es lo que está activo hoy.

Mientras no cargues `GOOGLE_SA_KEY`, **todo sigue funcionando con el fallback** — el deploy no rompe nada.

## Pasos en Google Cloud (una sola vez)

1. **Habilitar la API**: en la consola de GCP del proyecto que ya usás para Maps, andá a "APIs y servicios" → habilitar **"Route Optimization API"** (`routeoptimization.googleapis.com`). Requiere facturación habilitada en el proyecto (igual que Routes API).

2. **Crear un service account**: "IAM y administración" → "Cuentas de servicio" → Crear. Nombre ej. `route-optimizer`. Asignarle el rol **"Route Optimization Editor"** (`roles/routeoptimization.editor`).

3. **Crear una key JSON**: en la cuenta de servicio recién creada → "Claves" → "Agregar clave" → "Crear clave nueva" → tipo **JSON** → se descarga un archivo `.json` (contiene `client_email`, `private_key`, `project_id`, etc.). Guardalo seguro; no lo subas al repo.

## Cargar el secret en Supabase

En Supabase → tu proyecto → **Edge Functions → Secrets** → agregar:

- **Key**: `GOOGLE_SA_KEY`
- **Value**: el **contenido completo del archivo JSON** (pegá todo el JSON tal cual, con los `\n` de la `private_key` incluidos).

Después, **re-desplegá** la función `optimizar-ruta` (o esperá al próximo deploy). A partir de ahí, las optimizaciones usan Route Optimization API automáticamente.

## Costo

Free tier: **5.000 shipments/mes**. Cada `optimizeTours` con N paradas = N shipments. A ~26 armados de ruta/mes × 40-60 paradas ≈ 1.000-1.600 shipments → **gratis**.

## Verificación

- En Supabase → Edge Functions → `optimizar-ruta` → Logs, al armar una ruta:
  - con el secret cargado: el campo `optimizado_por` de la respuesta dice "Google Route Optimization".
  - sin el secret (o si falla): dice "Google Routes API (...)" — el fallback.
- En la consola de GCP → Route Optimization API → métricas, deberían aparecer las llamadas.

## Cómo se ve en el código
- `supabase/functions/optimizar-ruta/sa-auth.ts` — JWT RS256 + access_token (Web Crypto, cache ~1h).
- `supabase/functions/optimizar-ruta/route-optimization.ts` — request/parse de `optimizeTours`.
- `supabase/functions/optimizar-ruta/index.ts` — elige motor (SA vs computeRoutes) y mantiene el mismo shape de respuesta.
