/**
 * MapaRuta — mapa embebido (Leaflet + OpenStreetMap, sin API key ni costo)
 * con las paradas de una ruta de entrega.
 *
 * - Markers numerados según orden de entrega: azul = pendiente, verde = entregado.
 * - Marker del depósito (cuadrado oscuro "D") como origen/cierre de la ruta.
 * - Línea punteada conectando depósito → paradas en orden → depósito.
 * - Popup con cliente y dirección por parada.
 *
 * La navegación giro-a-giro NO se hace acá: siguen siendo los deep links a
 * Google Maps/Waze. Este mapa es para visualizar la ruta y su progreso
 * (transportista y admin en Operaciones > Recorridos).
 *
 * Importar siempre con lazy() — leaflet pesa ~150 KB y solo se usa en estas
 * dos vistas.
 */
import { useMemo } from 'react';
import { MapContainer, TileLayer, Marker, Popup, Polyline } from 'react-leaflet';
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

export interface MapaRutaProps {
  paradas: ParadaMapa[];
  /** Depósito (origen y cierre de la ruta). Opcional. */
  deposito?: { lat: number; lng: number } | null;
  /** Altura del mapa (CSS). Default 280px. */
  altura?: number;
}

const markerParada = (orden: number, entregado: boolean) =>
  divIcon({
    className: '', // sin clase default de leaflet (evita el sprite roto)
    html: `<div style="
      width:28px;height:28px;border-radius:9999px;
      background:${entregado ? '#22c55e' : '#2563eb'};
      color:#fff;font-weight:700;font-size:12px;
      display:flex;align-items:center;justify-content:center;
      border:2px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.4);
    ">${entregado ? '✓' : orden}</div>`,
    iconSize: [28, 28],
    iconAnchor: [14, 14],
    popupAnchor: [0, -14],
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

export default function MapaRuta({ paradas, deposito = null, altura = 280 }: MapaRutaProps) {
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
  // mejora futura si hace falta.
  const linea = useMemo((): LatLngExpression[] => {
    const pts: LatLngExpression[] = paradasOrdenadas.map(p => [p.lat, p.lng]);
    if (deposito && pts.length > 0) {
      return [[deposito.lat, deposito.lng], ...pts, [deposito.lat, deposito.lng]];
    }
    return pts;
  }, [paradasOrdenadas, deposito]);

  if (!bounds) return null;

  return (
    <div className="rounded-xl overflow-hidden border dark:border-gray-700" style={{ height: altura }}>
      <MapContainer
        bounds={bounds}
        style={{ height: '100%', width: '100%' }}
        scrollWheelZoom={false}
        attributionControl={true}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {linea.length > 1 && (
          <Polyline positions={linea} pathOptions={{ color: '#2563eb', weight: 3, dashArray: '6 8', opacity: 0.7 }} />
        )}
        {deposito && (
          <Marker position={[deposito.lat, deposito.lng]} icon={markerDeposito}>
            <Popup>Depósito</Popup>
          </Marker>
        )}
        {paradasOrdenadas.map(p => (
          <Marker key={`${p.orden}-${p.lat}-${p.lng}`} position={[p.lat, p.lng]} icon={markerParada(p.orden, !!p.entregado)}>
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
