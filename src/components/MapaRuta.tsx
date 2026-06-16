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
  /** Rumbo del GPS (grados, 0 = norte) o null. Para la cámara heading-up. */
  heading?: number | null;
  /** Velocidad del GPS (m/s) o null. */
  speed?: number | null;
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
  /** Zoom a aplicar UNA vez al activar el seguimiento (modo guía/navegación). */
  zoomSeguir?: number;
  /**
   * Modo guía activo: si hay Vector Map ID (VITE_GOOGLE_MAP_ID), activa la
   * cámara heading-up (acerca + inclina + rota al rumbo). Sin Map ID degrada a
   * seguimiento 2D (panTo). Solo lo implementa MapaRutaGoogle.
   */
  modoGuia?: boolean;
  /**
   * Ruta real sobre las calles (polyline decodificada de Google). Si viene con
   * >1 punto se dibuja la línea sólida real; si no, fallback a la línea recta
   * punteada entre paradas (recorridos viejos / sin polyline).
   */
  rutaReal?: [number, number][] | null;
  /**
   * Tramo de navegación activo (de la posición a la próxima parada). Si viene,
   * se dibuja RESALTADO por encima de la ruta del día (modo guía).
   */
  rutaTramo?: [number, number][] | null;
}

// Jerarquía visual: la parada activa domina (40px, anillo pulsante); las
// pendientes son medianas (28px); las completadas se "apagan" (20px, verde
// atenuado) para ceder protagonismo y desamontonar el centro.
const markerParada = (orden: number, entregado: boolean, activa: boolean) => {
  const size = activa ? 40 : entregado ? 20 : 28;
  const bg = entregado ? '#16a34a' : activa ? '#1d4ed8' : '#2563eb';
  const fontSize = activa ? 15 : entregado ? 10 : 12;
  const border = activa ? 3 : 2;
  return divIcon({
    className: '', // sin clase default de leaflet (evita el sprite roto)
    html: `<div class="${activa ? 'mapa-marker-activo' : ''}" style="
      width:${size}px;height:${size}px;border-radius:9999px;
      background:${bg};opacity:${entregado && !activa ? 0.65 : 1};
      color:#fff;font-weight:700;font-size:${fontSize}px;
      display:flex;align-items:center;justify-content:center;
      border:${border}px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.45);
    ">${entregado ? '✓' : orden}</div>`,
    iconSize: [size, size],
    iconAnchor: [size / 2, size / 2],
    popupAnchor: [0, -size / 2],
  });
};

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
  rutaReal = null,
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

  // Fallback: líneas rectas punteadas entre paradas en orden. Solo se usa
  // cuando no hay ruta real (recorridos viejos / sin polyline guardada).
  const lineaFallback = useMemo((): LatLngExpression[] => {
    const pts: LatLngExpression[] = paradasOrdenadas.map(p => [p.lat, p.lng]);
    if (deposito && pts.length > 0) {
      return [[deposito.lat, deposito.lng], ...pts, [deposito.lat, deposito.lng]];
    }
    return pts;
  }, [paradasOrdenadas, deposito]);

  const hayRutaReal = (rutaReal?.length ?? 0) > 1;

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
        {/* CARTO Voyager: base limpia y profesional (gratis). {r} sirve tiles
            @2x en pantallas retina (celulares). Atribución CARTO + OSM. */}
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> contributors &copy; <a href="https://carto.com/attributions">CARTO</a>'
          url="https://{s}.basemaps.cartocdn.com/rastertiles/voyager/{z}/{x}/{y}{r}.png"
          subdomains="abcd"
          maxZoom={20}
        />
        <VistaControlada objetivo={objetivo} />
        {hayRutaReal ? (
          // Ruta real sobre las calles: línea sólida.
          <Polyline positions={rutaReal as LatLngExpression[]} pathOptions={{ color: '#2563eb', weight: 5, opacity: 0.85 }} />
        ) : lineaFallback.length > 1 && (
          // Fallback recto punteado (sin polyline guardada).
          <Polyline positions={lineaFallback} pathOptions={{ color: '#2563eb', weight: 3, dashArray: '6 8', opacity: 0.6 }} />
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
