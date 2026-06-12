/**
 * MapaRuta — mapa embebido (Leaflet + OpenStreetMap, sin API key ni costo)
 * con las paradas de una ruta de entrega.
 *
 * - Markers numerados según orden de entrega: azul = pendiente, verde = entregado.
 * - Parada activa: marker más grande con anillo pulsante (clase CSS en index.css)
 *   y flyTo suave al cambiar.
 * - Posición propia (punto azul + círculo de precisión) si se pasa `posicion`.
 * - Marker del depósito (cuadrado oscuro "D") como origen/cierre de la ruta.
 * - Línea punteada conectando depósito → paradas en orden → depósito.
 * - `onParadaTap` permite sincronizar con UI externa (bottom sheet).
 *
 * La navegación giro-a-giro NO se hace acá: siguen siendo los deep links a
 * Google Maps/Waze. Importar siempre con lazy() — leaflet pesa ~150 KB.
 */
import { useEffect, useMemo } from 'react';
import { MapContainer, TileLayer, Marker, Popup, Polyline, Circle, useMap } from 'react-leaflet';
import { divIcon, latLngBounds } from 'leaflet';
import type { LatLngBoundsExpression, LatLngExpression } from 'leaflet';
import 'leaflet/dist/leaflet.css';

export interface ParadaMapa {
  lat: number;
  lng: number;
  orden: number;
  titulo: string;
  subtitulo?: string;
  entregado?: boolean;
}

export interface PosicionMapa {
  lat: number;
  lng: number;
  accuracy?: number;
}

export interface MapaRutaProps {
  paradas: ParadaMapa[];
  /** Depósito (origen y cierre de la ruta). Opcional. */
  deposito?: { lat: number; lng: number } | null;
  /** Altura del mapa: px, o 'full' para ocupar el contenedor (height 100%). */
  altura?: number | 'full';
  /** Posición actual del dispositivo (punto azul + precisión). */
  posicion?: PosicionMapa | null;
  /** Orden de la parada activa: marker destacado + flyTo al cambiar. */
  paradaActivaOrden?: number | null;
  /** Tap en un marker de parada. */
  onParadaTap?: (orden: number) => void;
  /** Si true, el mapa sigue la posición propia en vez de la parada activa. */
  seguirPosicion?: boolean;
}

const markerParada = (orden: number, entregado: boolean, activa: boolean) =>
  divIcon({
    className: '', // sin clase default de leaflet (evita el sprite roto)
    html: `<div class="${activa ? 'mapa-marker-activo' : ''}" style="
      width:${activa ? 36 : 28}px;height:${activa ? 36 : 28}px;border-radius:9999px;
      background:${entregado ? '#22c55e' : activa ? '#1d4ed8' : '#2563eb'};
      color:#fff;font-weight:700;font-size:${activa ? 14 : 12}px;
      display:flex;align-items:center;justify-content:center;
      border:${activa ? 3 : 2}px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.45);
    ">${entregado ? '✓' : orden}</div>`,
    iconSize: activa ? [36, 36] : [28, 28],
    iconAnchor: activa ? [18, 18] : [14, 14],
    popupAnchor: [0, activa ? -18 : -14],
  });

const markerDeposito = divIcon({
  className: '',
  html: `<div style="
    width:28px;height:28px;border-radius:6px;
    background:#1f2937;color:#fff;font-weight:700;font-size:12px;
    display:flex;align-items:center;justify-content:center;
    border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4);
  ">D</div>`,
  iconSize: [28, 28],
  iconAnchor: [14, 14],
  popupAnchor: [0, -14],
});

const markerPosicion = divIcon({
  className: '',
  html: `<div style="
    width:18px;height:18px;border-radius:9999px;
    background:#3b82f6;border:3px solid #fff;
    box-shadow:0 0 0 2px rgba(59,130,246,.35), 0 1px 4px rgba(0,0,0,.4);
  "></div>`,
  iconSize: [18, 18],
  iconAnchor: [9, 9],
});

/** Centra el mapa con animación cuando cambia el objetivo (parada activa o posición). */
function VistaControlada({ objetivo }: { objetivo: LatLngExpression | null }) {
  const map = useMap();
  useEffect(() => {
    if (objetivo) {
      map.flyTo(objetivo, Math.max(map.getZoom(), 15), { duration: 0.8 });
    }
  }, [map, objetivo]);
  return null;
}

export default function MapaRuta({
  paradas,
  deposito = null,
  altura = 280,
  posicion = null,
  paradaActivaOrden = null,
  onParadaTap,
  seguirPosicion = false,
}: MapaRutaProps) {
  const paradasOrdenadas = useMemo(
    () => [...paradas].sort((a, b) => a.orden - b.orden),
    [paradas],
  );

  const bounds = useMemo((): LatLngBoundsExpression | null => {
    const puntos: LatLngExpression[] = paradasOrdenadas.map(p => [p.lat, p.lng]);
    if (deposito) puntos.push([deposito.lat, deposito.lng]);
    if (puntos.length === 0) return null;
    return latLngBounds(puntos as [number, number][]).pad(0.15);
  }, [paradasOrdenadas, deposito]);

  // Trazado simple (líneas punteadas entre paradas en orden). El trazado real
  // sobre calles requeriría guardar la polyline de Google en recorridos —
  // fase 3 del plan de Ruta Activa.
  const linea = useMemo((): LatLngExpression[] => {
    const pts: LatLngExpression[] = paradasOrdenadas.map(p => [p.lat, p.lng]);
    if (deposito && pts.length > 0) {
      return [[deposito.lat, deposito.lng], ...pts, [deposito.lat, deposito.lng]];
    }
    return pts;
  }, [paradasOrdenadas, deposito]);

  const objetivo = useMemo((): LatLngExpression | null => {
    if (seguirPosicion && posicion) return [posicion.lat, posicion.lng];
    if (paradaActivaOrden != null) {
      const activa = paradasOrdenadas.find(p => p.orden === paradaActivaOrden);
      if (activa) return [activa.lat, activa.lng];
    }
    return null;
  }, [seguirPosicion, posicion, paradaActivaOrden, paradasOrdenadas]);

  if (!bounds) return null;

  const esFull = altura === 'full';

  return (
    <div
      className={`mapa-ruta overflow-hidden ${esFull ? 'h-full w-full' : 'rounded-xl border dark:border-gray-700'}`}
      style={esFull ? undefined : { height: altura }}
    >
      <MapContainer
        bounds={bounds}
        style={{ height: '100%', width: '100%' }}
        scrollWheelZoom={esFull}
        zoomControl={!esFull}
        attributionControl={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <VistaControlada objetivo={objetivo} />
        {linea.length > 1 && (
          <Polyline positions={linea} pathOptions={{ color: '#2563eb', weight: 3, dashArray: '6 8', opacity: 0.7 }} />
        )}
        {deposito && (
          <Marker position={[deposito.lat, deposito.lng]} icon={markerDeposito}>
            <Popup>Depósito</Popup>
          </Marker>
        )}
        {posicion && (
          <>
            {posicion.accuracy != null && posicion.accuracy > 15 && (
              <Circle
                center={[posicion.lat, posicion.lng]}
                radius={posicion.accuracy}
                pathOptions={{ color: '#3b82f6', weight: 1, opacity: 0.4, fillOpacity: 0.1 }}
              />
            )}
            <Marker position={[posicion.lat, posicion.lng]} icon={markerPosicion} zIndexOffset={1000} />
          </>
        )}
        {paradasOrdenadas.map(p => (
          <Marker
            key={`${p.orden}-${p.lat}-${p.lng}`}
            position={[p.lat, p.lng]}
            icon={markerParada(p.orden, !!p.entregado, p.orden === paradaActivaOrden)}
            zIndexOffset={p.orden === paradaActivaOrden ? 500 : 0}
            eventHandlers={onParadaTap ? { click: () => onParadaTap(p.orden) } : undefined}
          >
            <Popup>
              <strong>{p.orden}. {p.titulo}</strong>
              {p.subtitulo && <><br />{p.subtitulo}</>}
              {p.entregado && <><br />✓ Entregado</>}
            </Popup>
          </Marker>
        ))}
      </MapContainer>
    </div>
  );
}
