# Plan: "Ruta Activa" — experiencia map-first estilo Uber para el transportista

## Contexto

La base funcional de optimización de rutas ya está (PR #366: persistencia de recorridos, panel Recorridos, mapa Leaflet básico). El usuario quiere elevar la UI a nivel profesional: **el mapa como pantalla principal** para el transportista, con las tarjetas de pedido integradas al mapa (bottom sheet), navegación integrada al flujo, llegada auto-detectada por GPS, y posición del camión en vivo visible también para el admin.

Decisiones tomadas en brainstorming con el usuario:
- Visión: **mapa a pantalla completa estilo Uber/Rappi** (no híbrido, no turn-by-turn propio — la navegación giro a giro sigue siendo deep link a Google Maps/Waze).
- **GPS en vivo: sí, y el admin lo ve** en Operaciones > Recorridos.
- **Auto-detectar llegada** (geofence ~100m) con avance automático a la siguiente parada.
- **Por fases** — un PR por fase, cada una desplegable y usable por sí sola.
- Limitación aceptada: al ser PWA, el GPS solo reporta con la app abierta en pantalla (uso esperado: celu montado con la app abierta).

Stack: Leaflet + OSM ya instalado (`MapaRuta.tsx`); cero costo de APIs.

---

## FASE 1 — Pantalla "Ruta Activa" del transportista (este PR)

Reemplaza `VistaRutaTransportista` (lista vertical) por una pantalla map-first cuando el rol es transportista (punto de montaje: [VistaPedidos.tsx:156](src/components/vistas/VistaPedidos.tsx)).

### Componentes nuevos

**`src/components/rutaActiva/RutaActivaTransportista.tsx`** — pantalla principal:
- Mapa full-viewport (100dvh menos el header de la app), `MapaRuta` evolucionado: markers tappables (tocar una parada la selecciona en el sheet), modo "seguir mi posición" con botón de re-centrar, punto azul de posición propia con círculo de precisión.
- Header flotante compacto sobre el mapa: progreso del día (3/12 entregas, $ por cobrar) + botón para abrir la lista completa.
- Banner offline existente reutilizado.

**`src/components/rutaActiva/SheetParada.tsx`** — bottom sheet con 3 posiciones (colapsado / medio / expandido):
- Librería: `vaul` (~5 KB, drawer de Radix — ya usan @radix-ui; React 19 OK). Snap points nativos.
- **Colapsado**: píldora con "Siguiente: Cliente X · 1.2 km".
- **Medio (default)**: tarjeta de la parada activa — orden, cliente, dirección + aclaración para repartidores, teléfono (tap to call), total y estado de pago, cantidad de items; botones grandes: **Navegar** (sheet Maps/Waze existente), **Entregar** (flujo actual completo: cobro/sin cobrar/salvedad), **Problema** (salvedad).
- **Expandido**: lista completa de paradas (reutilizar `EntregaRutaCard` simplificada), tap selecciona y baja a modo medio.
- Estado "**Llegaste**": cuando el GPS está a <100m de la parada activa, la tarjeta cambia de color/CTA (Entregar pasa a primario). Al marcar entregado, avanza sola a la siguiente parada y el CTA vuelve a Navegar.

**`src/hooks/useWatchPosition.ts`** — `navigator.geolocation.watchPosition` con cleanup, throttle y estado (coords, accuracy, heading, error). Base para el geofence (distancia haversine a la parada activa) y para el tracking de Fase 2.

### Reuso (no reescribir)
- Flujo de entrega/cobro/salvedad: extraer de `VistaRutaTransportista` los handlers (`handleMarcarEntregado`, modal de pago, salvedad, entregar sin cobrar) a un hook compartido `useEntregaParada` para que la pantalla nueva y la vieja (que queda como fallback temporal) usen lo mismo.
- `googleMapsNavUrl`/`wazeNavUrl` ([utils/navegacion](src/utils/navegacion.ts)), `getDepositoCoords`, links por tramos ya implementados (se mueven al menú "..." del sheet).
- Orden de paradas: sigue leyendo `pedidos.orden_entrega` (ya persistido por la RPC `aplicar_orden_ruta`).

### Detalles de UI profesional
- Transiciones: el mapa hace `flyTo` suave al cambiar de parada activa; marker activo más grande con anillo pulsante (CSS).
- Dark mode: tiles OSM con filtro CSS (`filter: brightness/invert` en clase dark) — patrón estándar Leaflet.
- Touch targets ≥44px, safe-area-inset para notch/gestos.

## FASE 2 — Tracking en vivo + mapa de flota del admin (PR siguiente)

- **Migración 082**: tabla `transportista_ubicaciones` (PK transportista_id; lat, lng, heading, speed, accuracy, recorrido_id, sucursal_id, updated_at). RLS: el transportista upsertea solo la suya; admin/encargado leen las de su sucursal. Habilitar Realtime en la tabla.
- **`useReportarUbicacion`**: mientras hay recorrido en curso y la pantalla está visible (`document.visibilityState`), upsert cada 30s o >100m de movimiento (lo que ocurra primero), vía `useWatchPosition`.
- **Admin — Operaciones > Recorridos**: `MapaFlota` arriba del listado — camiones en vivo (suscripción Supabase Realtime a `transportista_ubicaciones`), con ícono de camión + nombre + "hace Xs"; al seleccionar un recorrido se muestran sus paradas con estado. Indicador "señal congelada" si updated_at > 3 min.

## FASE 3 — Pulido visual (PR final)

- **Ruta sobre calles reales**: migración 083 agrega `recorridos.polyline text[]`; la edge function `optimizar-ruta` agrega `routes.polyline` al FieldMask y devuelve el encoded polyline por tramo; `aplicar_orden_ruta` lo recibe y guarda; decoder de polyline (~30 líneas, sin dependencia) y se dibuja en vez de la línea punteada.
- Micro-animaciones (entrega completada: marker hace pop a verde), skeletons de carga del mapa, ajustes finos de dark mode y del sheet.

---

## Verificación (Fase 1)
1. `npm run typecheck`, lint, suite completa (pre-commit), build.
2. Manual con Preview/dev: rol transportista con pedidos asignados → mapa full-screen, sheet con parada 1; simular posición (DevTools sensors) cerca del cliente → estado "Llegaste"; entregar → avanza a parada 2; cobro y salvedad funcionan igual que hoy.
3. La vista del admin y los PDFs no cambian en esta fase.
4. Compromiso del documento de diseño: guardar este diseño en `docs/plans/2026-06-12-ruta-activa-design.md` como primer commit del PR.
