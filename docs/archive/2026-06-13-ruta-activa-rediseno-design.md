# Plan: Rediseño "Ruta Activa" — depósito correcto, ruta real sobre calles, look profesional

## Contexto

La pantalla map-first del transportista (PR #367) salió funcional pero con problemas reales, vistos en producción:

1. **Depósito mal ubicado (bug)**: `getDepositoCoords()` ([useOptimizarRuta.ts](src/hooks/useOptimizarRuta.ts)) lee de **localStorage (por dispositivo)**. El admin lo configura en su PC; el celular del transportista tiene localStorage vacío → cae al default (centro de Tucumán = la "D" del screenshot). La ruta se optimizó con un depósito y el mapa muestra otro. `sucursales` no tiene columnas de coordenadas.
2. **"808.4 km" de distancia**: el GPS lee la ubicación del escritorio al testear (accuracy pésima). En celular real andaría, pero el dato basura no debe mostrarse.
3. **Telaraña de líneas rectas**: `MapaRuta` dibuja una Polyline recta depósito→paradas→depósito. Google ya calcula la ruta real sobre las calles al optimizar (la pagamos), pero el FieldMask no la pide y se descarta.
4. **Markers amontonados + tiles crudos**: sin jerarquía visual; tiles OSM crudos se ven artesanales.

**Decisiones tomadas con el usuario (brainstorming):**
- Mapa: **seguir con Leaflet** (costo $0) pero con tiles **CARTO Voyager** (limpios, retina) + ruta real sobre calles.
- Navegación: **ruta real dentro de la app + handoff a Google Maps/Waze** para el manejo con voz (lo que hacen las apps de delivery; turn-by-turn propio se descarta por no ser realista en PWA).
- Depósito: **a la base de datos por sucursal**, configurado desde el modal de optimización donde ya está.
- Alcance: **solo experiencia del transportista** este PR (el camión en vivo para el admin es otro PR). El mapa del admin en Recorridos igual se beneficia de la ruta real y el depósito correcto.

Stack ya presente: Leaflet + react-leaflet + vaul, edge function `optimizar-ruta` (parte en tramos ≤23 con `optimizeWaypointOrder`), RPC `aplicar_orden_ruta` (mig 081), tabla `recorridos`/`recorrido_pedidos`, TanStack Query. Gate `es_encargado_o_admin()` y `current_sucursal_id()` confirmados en prod.

---

## Implementación

### A. Depósito en DB por sucursal (cierra bug #1)

**Migración `082_sucursales_deposito_coords.sql`** (aplicar a prod vía MCP + versionar, patrón mig 081):
- `ALTER TABLE sucursales ADD COLUMN deposito_lat double precision, ADD COLUMN deposito_lng double precision;`
- Seed solo Tucumán (id=1, el default coincide geográficamente): `UPDATE ... WHERE id=1 AND deposito_lat IS NULL`. Las otras quedan NULL → fallback al default hasta configurarlas.
- RPC `get_deposito_sucursal()` (lee de `current_sucursal_id()`, SECURITY DEFINER, GRANT authenticated — el transportista necesita leer).
- RPC `set_deposito_sucursal(p_lat, p_lng)` con gate `es_encargado_o_admin()` (42501), escribe en la sucursal actual.

**`src/hooks/queries/useDepositoQuery.ts`** (nuevo): `useDepositoCoords()` (useQuery sobre `get_deposito_sucursal`, `placeholderData: DEPOSITO_DEFAULT` → **siempre devuelve `{lat,lng}` usable**, sin async en el render) + `useSetDepositoMutation()`. queryKey incluye `currentSucursalId`.

**Migrar los call sites de `getDepositoCoords()`** a `useDepositoCoords()`: [RutaActivaTransportista.tsx](src/components/rutaActiva/RutaActivaTransportista.tsx), [VistaRecorridos.tsx](src/components/vistas/VistaRecorridos.tsx) (dentro de `RecorridoCard`), [ModalGestionRutas.tsx](src/components/modals/ModalGestionRutas.tsx) (carga + guardar con la mutation), `ModalOptimizarRuta.tsx`, `ModalOptimizarRutaPreventista.tsx`. `getDepositoCoords`/`DEPOSITO_DEFAULT` quedan como fallback puro `@deprecated` (sin escribir localStorage).

**`optimizarRuta` deja de leer el depósito internamente**: pasa a recibirlo por parámetro; el caller ([PedidosContainer.tsx](src/components/containers/PedidosContainer.tsx)) lo lee de `useDepositoCoords()` y lo pasa. Así el lado que optimiza y el que dibuja usan la **misma** fuente (DB) — raíz del bug eliminada.

### B. Ruta real sobre las calles (cierra #3)

**Edge function** [optimizar-ruta](supabase/functions/optimizar-ruta/index.ts):
- FieldMask: agregar `routes.polyline.encodedPolyline`; body explícito `polylineEncoding: "ENCODED_POLYLINE"`.
- `tramos.ts`: agregar `polyline?.encodedPolyline` a `GoogleRoute`; `unirTramos` recolecta `polylines: string[]` (una por tramo, en orden).
- Respuesta JSON suma `polylines: [...]`.

**Migración `083_recorridos_polyline.sql`**: `ALTER TABLE recorridos ADD COLUMN polylines jsonb;` + **DROP** de la firma vieja de `aplicar_orden_ruta(uuid,jsonb,numeric,integer)` y CREATE con `p_polylines jsonb DEFAULT NULL` (evita overload ambiguo en PostgREST); el INSERT guarda las polylines.

**Front**:
- `src/utils/polyline.ts` (nuevo): `decodePolyline` (algoritmo Google precisión 1e5, ~30 líneas, sin dependencia) + `decodePolylines(string[])` que decodifica y concatena tramos. Devuelve `[lat,lng][]` (formato directo de Leaflet). Test unitario contra un encoded conocido.
- [useOptimizarRuta.ts](src/hooks/useOptimizarRuta.ts): `polylines?: string[]` en `RutaOptimizadaResponse` (el campo `polyline?` viejo sin uso se reemplaza).
- [PedidosContainer.tsx](src/components/containers/PedidosContainer.tsx) `aplicarOrden`: pasa `p_polylines: rutaOptimizada.polylines ?? null`.
- `src/hooks/queries/useRecorridoActivoQuery.ts` (nuevo): recorrido `en_curso` de hoy del transportista (`.maybeSingle()`), trae `polylines`.
- [MapaRuta.tsx](src/components/MapaRuta.tsx): prop `rutaReal?: [number,number][]`; si viene, Polyline **sólida** sobre calles; si no, fallback a la recta punteada actual (degradado elegante para recorridos viejos / sin polyline).
- [RutaActivaTransportista.tsx](src/components/rutaActiva/RutaActivaTransportista.tsx): consume `useRecorridoActivoQuery` → decode → `rutaReal`.
- [useRecorridos.ts](src/hooks/supabase/useRecorridos.ts) + [VistaRecorridos.tsx](src/components/vistas/VistaRecorridos.tsx): `polylines` en el select y `rutaReal` al mapa del admin. `RecorridoDBExtended` suma `polylines`.

Las paradas y el flujo de entrega siguen leyendo `pedidos.orden_entrega`; el recorrido se usa **solo** para la polyline → si la query falla, el flujo no se rompe.

### C. Tiles CARTO + jerarquía de markers (cierra #4 visual)

- [MapaRuta.tsx](src/components/MapaRuta.tsx) TileLayer → CARTO Voyager (`https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png`, `subdomains="abcd"`, atribución "© OpenStreetMap contributors © CARTO", `{r}` retina).
- **CSP (bloqueante)**: [index.html](index.html) `img-src` suma `https://*.basemaps.cartocdn.com` (sin esto el mapa queda gris, sin error visible).
- Jerarquía de markers (sin clustering — en una ruta querés ver todas las paradas): activa 40px destacada con anillo pulsante; pendientes 28px; **completadas 20px verdes atenuadas (opacity ~0.6)** para ceder protagonismo. La ruta real guía el ojo entre paradas céntricas juntas.

### D. Gating de GPS + pulido del sheet (cierra #2 y experiencia)

- [RutaActivaTransportista.tsx](src/components/rutaActiva/RutaActivaTransportista.tsx): `gpsConfiable = accuracy <= 1000m`; `distanciaMetros = null` si no confiable o si la distancia a la parada > 50km (fuera de zona). `llegaste` solo con GPS confiable. `posicion` al mapa solo si confiable (no plantar el punto azul en medio del país). Reusa `haversineMeters`/`formatDistancia` ([geo.ts](src/utils/geo.ts)) y `useWatchPosition`.
- [SheetParada.tsx](src/components/rutaActiva/SheetParada.tsx): con GPS impreciso, microcopy honesto ("Ubicación imprecisa") en vez de distancia falsa; Entregar disponible pero secundario (Navegar es el CTA dominante). Al entrar en "Llegaste" auto-subir el sheet a snap medio. Skeleton de la parada activa mientras carga. No tocar `useEntregaParada` (lógica de entrega/cobro/salvedad intacta).

---

## Secuencia de build (cada paso compila y se verifica aislado)

1. Migración 082 + RPCs → verificar en vivo: `get_deposito_sucursal()` devuelve coords (admin), `set_deposito_sucursal` bloquea transportista (42501).
2. `useDepositoQuery` + migrar los 5 call sites → la "D" coincide en admin y transportista; el modal persiste a DB. **Bug #1 cerrado.**
3. `utils/polyline.ts` + test de decode.
4. Edge function FieldMask + `polylines` → deploy; la respuesta trae `polylines`.
5. Migración 083 + `aplicar_orden_ruta` con `p_polylines` + wire en `aplicarOrden` → aplicar orden guarda polylines.
6. MapaRuta `rutaReal` + tiles CARTO + jerarquía markers + **CSP (paso bloqueante junto a este)**.
7. `useRecorridoActivoQuery` + wire en RutaActivaTransportista → transportista ve ruta real; sin recorrido, fallback recto.
8. VistaRecorridos: polylines en select + rutaReal en mapa admin.
9. Gating GPS + pulido SheetParada.

## Riesgos / gotchas

- **CSP**: agregar `*.basemaps.cartocdn.com` a `img-src` o el mapa queda gris sin error.
- **Overload de `aplicar_orden_ruta`**: DROP de la firma de 4 args antes del CREATE de 5; el front siempre manda los 5 (con `null`).
- **Tipo polylines = jsonb** (no `text[]`): serialización transparente con supabase-js.
- **Costo Google**: pedir `routes.polyline` no sube el SKU (ya estamos en TRAFFIC_AWARE); verificar en Cloud console post-deploy.
- **Recorridos viejos / sin polyline**: `polylines=NULL` → fallback recto; `.maybeSingle()` y manejar null.
- **Cache depósito**: la mutation invalida `depositoKeys`; el switch de sucursal ya invalida global.

## Verificación end-to-end

1. `npm run typecheck`, lint, suite completa (pre-commit), build, deno test de la edge function.
2. RPCs probadas en vivo con transacción+rollback (patrón mig 080/081).
3. Manual: admin configura depósito → optimiza → aplica orden (guarda polylines) → la "D" y la ruta real coinciden en el mapa del transportista y en Recorridos; en desktop no aparece "808 km" (estado neutro); en móvil/simulación el geofence anda.
4. Guardar el diseño en `docs/plans/2026-06-13-ruta-activa-rediseno-design.md` (primer commit del PR).
5. PR a main con los pasos manuales en el body (configurar depósitos de las sucursales 2 y 4, que quedan NULL).
