# Optimización de ruta con más de 25 pedidos (2026-06)

> **ACTUALIZACIÓN**: la solución definitiva es la Edge Function
> `supabase/functions/optimizar-ruta` (misma lógica de tramos, API key como
> secret del servidor, JWT obligatorio). El frontend la invoca primero y solo
> cae al webhook de n8n como fallback. Los workflows de n8n (v1 y v2) quedan
> como respaldo y se pueden retirar cuando la edge function esté consolidada
> — en ese momento eliminar también `VITE_GOOGLE_API_KEY` del bundle.
> Requisito: configurar el secret `GOOGLE_API_KEY` en Supabase
> (Dashboard → Edge Functions → Secrets).

## Problema

El workflow de n8n **"Optimizar Ruta Transportista"** (`vyrzbP92Zmokh3Ll`, webhook
`/webhook/optimizar-ruta`) hace una única llamada a Google Routes API
`computeRoutes` con `optimizeWaypointOrder: true`. Esa API tiene un **límite duro
de 25 waypoints intermedios por request** → con 26+ pedidos Google devuelve error.

## Solución: partir en tramos por barrido angular

Se creó el workflow **"Optimizar Ruta Transportista v2 (tramos >25 pedidos)"**
(`Mx8bpanMZjL7q0WF`, webhook `/webhook/optimizar-ruta-v2`), **inactivo** hasta
revisión. Misma API, mismo request/response hacia la app, pero:

1. **Preparar Waypoints**: ordena las paradas por ángulo alrededor del depósito
   (algoritmo de barrido clásico para VRP) y las parte en tramos contiguos de
   ≤23 paradas. Cada tramo se encadena con el siguiente mediante una parada
   "puente": la última del tramo es el destino de su request y el origen del
   request siguiente. Recorrido: depósito → tramo 1 → puente → tramo 2 → … → depósito.
2. **Google Routes API**: el nodo HTTP corre una vez por tramo (n8n itera los
   items automáticamente). Cada request tiene ≤23 intermedios → nunca pega el límite.
3. **Procesar Respuesta Google**: une los tramos en un solo `orden_optimizado`
   global, suma distancias/duraciones de todos los legs (incluida la vuelta al
   depósito) y devuelve el mismo shape que v1.

Con ≤23 pedidos genera **un solo tramo** y se comporta exactamente igual que v1.

## Costo

- Routes API `computeRoutes` con `optimizeWaypointOrder` + `TRAFFIC_AWARE` y
  11–25 intermedios factura como SKU **Enterprise**: 1.000 llamadas gratis/mes,
  luego USD 15 por 1.000.
- Una ruta de 50–70 pedidos = **2–3 requests**. Con ~26 armados de ruta al mes
  son ~80 requests/mes → **dentro del tier gratuito, costo USD 0**.
- Alternativa descartada: Route Optimization API (`optimizeTours`) maneja 100+
  paradas en una sola llamada y también entraría gratis (5.000 shipments/mes),
  pero **no acepta API key** — requiere service account OAuth de GCP configurada
  en n8n. Si algún día se superan los ~500 pedidos por ruta, migrar a esa.

## Cómo activar

Opción A (recomendada): activar el workflow v2 en n8n y cambiar
`VITE_N8N_WEBHOOK_URL` al webhook `/webhook/optimizar-ruta-v2` (re-deploy del front).

Opción B: copiar el código de los nodos "Preparar Waypoints" y "Procesar
Respuesta Google" del v2 dentro del workflow v1 (misma URL, sin re-deploy).
El v1 queda como rollback en el historial de versiones de n8n.
