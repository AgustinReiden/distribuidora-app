/* global google */
/**
 * MapaRutaGoogle — mapa de la pantalla Ruta Activa con Google Maps JS.
 *
 * Reemplaza a MapaRuta (Leaflet). Mismas props. Implementado de forma
 * IMPERATIVA (markers/polyline por refs, patrón de MapaPreventistas) para
 * resolver la mala reactividad: la posición propia (GPS cada ~4s) se actualiza
 * en un efecto AISLADO con `marker.setPosition`, sin recrear los markers de
 * paradas ni re-renderizar el árbol React.
 *
 * Importar siempre con lazy() — Google Maps JS se carga bajo demanda.
 */
import React, { useEffect, useRef, useState } from 'react';
import { Loader2, MapPin } from 'lucide-react';
import { useGoogleMaps } from '../../hooks/useGoogleMaps';
import { haversineMeters, computeBearing } from '../../utils/geo';
import type { MapaRutaProps } from '../MapaRuta';

const FALLBACK_CENTER = { lat: -26.8083, lng: -65.2176 };

// Vector Map ID (Google Cloud) → habilita la cámara heading-up (tilt + rotación).
// Si no está seteado, el mapa degrada a raster 2D con seguimiento por panTo, sin
// romper nada (clave para que el build sin la env siga andando).
const MAP_ID = import.meta.env.VITE_GOOGLE_MAP_ID ?? '';
const USAR_VECTOR = MAP_ID !== '';
/** Inclinación (tilt) de la cámara en modo guía. */
const TILT_GUIA = 50;

function circleSymbol(color: string, scale: number, opacity = 1): google.maps.Symbol {
  return {
    path: google.maps.SymbolPath.CIRCLE,
    fillColor: color,
    fillOpacity: opacity,
    strokeColor: '#ffffff',
    strokeWeight: 2,
    scale,
  };
}

/** Flecha de "vos estás acá" para el modo guía: apunta arriba (= adelante, porque
 *  el mapa rota al rumbo). */
function flechaSymbol(color: string, scale: number): google.maps.Symbol {
  return {
    path: google.maps.SymbolPath.FORWARD_CLOSED_ARROW,
    fillColor: color,
    fillOpacity: 1,
    strokeColor: '#ffffff',
    strokeWeight: 2,
    scale,
    rotation: 0,
  };
}

export default function MapaRutaGoogle({
  paradas,
  deposito = null,
  altura = 280,
  posicion = null,
  paradaActivaOrden = null,
  onParadaTap,
  seguirPosicion = false,
  zoomSeguir,
  rutaReal = null,
  rutaTramo = null,
  modoGuia = false,
}: MapaRutaProps): React.ReactElement {
  const { isLoaded, isLoading, error } = useGoogleMaps();
  const containerRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<google.maps.Map | null>(null);
  const markersRef = useRef<google.maps.Marker[]>([]);
  const depositoMarkerRef = useRef<google.maps.Marker | null>(null);
  const polylineRef = useRef<google.maps.Polyline | null>(null);
  const tramoPolylineRef = useRef<google.maps.Polyline | null>(null);
  const posMarkerRef = useRef<google.maps.Marker | null>(null);
  const posCircleRef = useRef<google.maps.Circle | null>(null);
  const fitSignatureRef = useRef<string>('');
  // El zoom de seguimiento se aplica una sola vez al entrar en follow (no en
  // cada tick) para no pelear con el pinch-zoom del chofer.
  const zoomSeguirAplicadoRef = useRef<boolean>(false);
  // Cámara heading-up (modo guía con Vector Map ID): rAF que interpola la cámara.
  const camRef = useRef<{ lat: number; lng: number; heading: number; tilt: number } | null>(null);
  const camTargetRef = useRef<{ lat: number; lng: number; heading: number; tilt: number } | null>(null);
  const rafRef = useRef<number | null>(null);
  const headingRef = useRef<number>(0);
  const prevPosRef = useRef<{ lat: number; lng: number } | null>(null);
  const animarRef = useRef<() => void>(() => {});
  const [mapReady, setMapReady] = useState(false);

  // 1) Inicializar el mapa una sola vez.
  useEffect(() => {
    if (!isLoaded || !containerRef.current || mapRef.current) return;
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps;
    if (!g) return;
    mapRef.current = new g.Map(containerRef.current, {
      center: deposito ?? FALLBACK_CENTER,
      zoom: 13,
      // Vector map (si hay Map ID) para poder tiltar/rotar la cámara en guía.
      // El Map ID ya está configurado como vector en la consola; con pasar mapId
      // alcanza (no forzamos renderingType para evitar conflictos).
      ...(USAR_VECTOR ? { mapId: MAP_ID } : {}),
      mapTypeControl: false,
      streetViewControl: false,
      fullscreenControl: false,
      clickableIcons: false,
      gestureHandling: 'greedy',
    });
    setMapReady(true);
  }, [isLoaded, deposito]);

  // 2) Paradas + ruta real + depósito. Recrea solo cuando cambian estos datos
  //    (NO en cada tick de GPS). fitBounds solo cuando cambia el set de paradas.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps;
    if (!g) return;
    const map = mapRef.current;

    // Limpiar lo anterior
    for (const m of markersRef.current) m.setMap(null);
    markersRef.current = [];
    if (depositoMarkerRef.current) { depositoMarkerRef.current.setMap(null); depositoMarkerRef.current = null; }
    if (polylineRef.current) { polylineRef.current.setMap(null); polylineRef.current = null; }

    const ordenadas = [...paradas].sort((a, b) => a.orden - b.orden);
    const bounds = new g.LatLngBounds();

    // Depósito
    if (deposito) {
      depositoMarkerRef.current = new g.Marker({
        position: { lat: deposito.lat, lng: deposito.lng },
        map,
        title: 'Depósito',
        label: { text: 'D', color: '#ffffff', fontWeight: '700', fontSize: '11px' },
        icon: circleSymbol('#1f2937', 9),
        zIndex: 50,
      });
      bounds.extend({ lat: deposito.lat, lng: deposito.lng });
    }

    // Paradas: activa grande/destacada, completadas verdes atenuadas, pendientes azules
    for (const p of ordenadas) {
      const activa = p.orden === paradaActivaOrden;
      const color = p.entregado ? '#16a34a' : activa ? '#1d4ed8' : '#2563eb';
      const scale = activa ? 13 : p.entregado ? 7 : 10;
      const marker = new g.Marker({
        position: { lat: p.lat, lng: p.lng },
        map,
        title: `${p.orden}. ${p.titulo}`,
        label: { text: p.entregado ? '✓' : String(p.orden), color: '#ffffff', fontWeight: '700', fontSize: activa ? '13px' : '11px' },
        icon: circleSymbol(color, scale, p.entregado && !activa ? 0.7 : 1),
        zIndex: activa ? 1000 : p.entregado ? 20 : 100 + p.orden,
      });
      if (onParadaTap) marker.addListener('click', () => onParadaTap(p.orden));
      markersRef.current.push(marker);
      bounds.extend({ lat: p.lat, lng: p.lng });
    }

    // Ruta real sobre las calles, o fallback recto depósito→paradas→depósito
    const hayRutaReal = (rutaReal?.length ?? 0) > 1;
    if (hayRutaReal) {
      polylineRef.current = new g.Polyline({
        path: (rutaReal as [number, number][]).map(([lat, lng]) => ({ lat, lng })),
        map,
        geodesic: false,
        strokeColor: '#2563eb',
        strokeOpacity: 0.85,
        strokeWeight: 5,
      });
    } else if (ordenadas.length > 0) {
      const path: google.maps.LatLngLiteral[] = [];
      if (deposito) path.push({ lat: deposito.lat, lng: deposito.lng });
      for (const p of ordenadas) path.push({ lat: p.lat, lng: p.lng });
      if (deposito) path.push({ lat: deposito.lat, lng: deposito.lng });
      if (path.length > 1) {
        polylineRef.current = new g.Polyline({
          path, map, geodesic: false, strokeColor: '#2563eb', strokeOpacity: 0.55, strokeWeight: 3,
          icons: [{ icon: { path: 'M 0,-1 0,1', strokeOpacity: 0.6, scale: 3 }, offset: '0', repeat: '14px' }],
        });
      }
    }

    // fitBounds solo cuando cambió el conjunto de paradas (no en cada selección)
    const signature = ordenadas.map(p => `${p.orden}:${p.lat},${p.lng}`).join('|') + (deposito ? `|D${deposito.lat},${deposito.lng}` : '');
    if (signature !== fitSignatureRef.current) {
      fitSignatureRef.current = signature;
      if (ordenadas.length + (deposito ? 1 : 0) === 1) {
        map.setCenter(bounds.getCenter());
        map.setZoom(15);
      } else if (ordenadas.length > 0 || deposito) {
        map.fitBounds(bounds, 64);
      }
    }
  }, [mapReady, paradas, deposito, rutaReal, paradaActivaOrden, onParadaTap]);

  // 3) Posición propia: efecto AISLADO. Solo mueve el punto azul + el círculo de
  //    precisión, sin tocar los markers de paradas. Esto mata el re-render por GPS.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps;
    if (!g) return;
    const map = mapRef.current;

    if (!posicion) {
      if (posMarkerRef.current) { posMarkerRef.current.setMap(null); posMarkerRef.current = null; }
      if (posCircleRef.current) { posCircleRef.current.setMap(null); posCircleRef.current = null; }
      return;
    }
    const pos = { lat: posicion.lat, lng: posicion.lng };
    // En guía con cámara heading-up, la posición es una flecha (apunta adelante);
    // si no, el punto azul de siempre.
    const icon = USAR_VECTOR && modoGuia ? flechaSymbol('#2563eb', 6) : circleSymbol('#3b82f6', 6);
    if (!posMarkerRef.current) {
      posMarkerRef.current = new g.Marker({ position: pos, map, icon, zIndex: 2000 });
    } else {
      posMarkerRef.current.setPosition(pos);
      posMarkerRef.current.setIcon(icon);
    }
    if (posicion.accuracy != null && posicion.accuracy > 15) {
      if (!posCircleRef.current) {
        posCircleRef.current = new g.Circle({
          map, center: pos, radius: posicion.accuracy,
          strokeColor: '#3b82f6', strokeOpacity: 0.4, strokeWeight: 1, fillColor: '#3b82f6', fillOpacity: 0.1,
        });
      } else {
        posCircleRef.current.setCenter(pos);
        posCircleRef.current.setRadius(posicion.accuracy);
      }
    } else if (posCircleRef.current) {
      posCircleRef.current.setMap(null);
      posCircleRef.current = null;
    }
  }, [mapReady, posicion, modoGuia]);

  // 4) Encuadre dinámico: seguir la posición propia o centrar en la parada activa.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    // En modo guía vector, la cámara la maneja el rAF heading-up (efecto 4b).
    if (USAR_VECTOR && modoGuia) return;
    const map = mapRef.current;
    if (seguirPosicion && posicion) {
      map.panTo({ lat: posicion.lat, lng: posicion.lng });
      // Acercar la cámara una sola vez al entrar en seguimiento (modo guía).
      if (zoomSeguir != null && !zoomSeguirAplicadoRef.current) {
        map.setZoom(zoomSeguir);
        zoomSeguirAplicadoRef.current = true;
      }
      return;
    }
    zoomSeguirAplicadoRef.current = false;
    if (paradaActivaOrden != null) {
      const activa = paradas.find(p => p.orden === paradaActivaOrden);
      if (activa) map.panTo({ lat: activa.lat, lng: activa.lng });
    }
  }, [mapReady, seguirPosicion, zoomSeguir, posicion, paradaActivaOrden, paradas, modoGuia]);

  // 4a) Loop de animación de la cámara: interpola la cámara actual hacia el
  //     target en cada frame (rumbo por el camino más corto, sin spin en 0/360).
  //     Se apaga al converger (ahorro de batería) y lo re-despierta cada fix.
  useEffect(() => {
    animarRef.current = () => {
      const cam = camRef.current;
      const tgt = camTargetRef.current;
      const map = mapRef.current;
      if (!cam || !tgt || !map) { rafRef.current = null; return; }
      const k = 0.2;
      const dh = ((tgt.heading - cam.heading + 540) % 360) - 180;
      cam.heading = (cam.heading + dh * k + 360) % 360;
      cam.lat += (tgt.lat - cam.lat) * k;
      cam.lng += (tgt.lng - cam.lng) * k;
      cam.tilt += (tgt.tilt - cam.tilt) * k;
      map.moveCamera({ center: { lat: cam.lat, lng: cam.lng }, heading: cam.heading, tilt: cam.tilt });
      const convergio = Math.abs(dh) < 0.5
        && Math.abs(tgt.lat - cam.lat) < 1e-6
        && Math.abs(tgt.lng - cam.lng) < 1e-6
        && Math.abs(tgt.tilt - cam.tilt) < 0.5;
      rafRef.current = convergio ? null : requestAnimationFrame(animarRef.current);
    };
  }, []);

  // 4b) Cámara heading-up (modo guía con Vector Map ID): centra, inclina (tilt) y
  //     rota al rumbo siguiendo la posición. Sin Vector Map ID no hace nada y
  //     queda el seguimiento 2D del efecto 4.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const map = mapRef.current;

    if (!(USAR_VECTOR && modoGuia && posicion)) {
      // Salir del modo cámara: frenar el loop y volver a norte-up plano.
      if (rafRef.current != null) { cancelAnimationFrame(rafRef.current); rafRef.current = null; }
      if (camRef.current) {
        camRef.current = null;
        camTargetRef.current = null;
        prevPosRef.current = null;
        map.moveCamera({ heading: 0, tilt: 0 });
      }
      return;
    }

    const pos = { lat: posicion.lat, lng: posicion.lng };
    // Rumbo: del GPS si lo da; si no, derivado del movimiento; si no, el último.
    let heading = headingRef.current;
    if (posicion.heading != null && Number.isFinite(posicion.heading)) {
      heading = posicion.heading;
    } else if (prevPosRef.current && haversineMeters(prevPosRef.current, pos) > 4) {
      heading = computeBearing(prevPosRef.current, pos);
    }
    headingRef.current = heading;
    prevPosRef.current = pos;

    if (!camRef.current) {
      // Recién entramos en guía: ubicar la cámara de una y fijar el zoom cercano.
      camRef.current = { lat: pos.lat, lng: pos.lng, heading, tilt: TILT_GUIA };
      map.setZoom(zoomSeguir ?? 17);
      map.moveCamera({ center: pos, heading, tilt: TILT_GUIA });
    }
    camTargetRef.current = { lat: pos.lat, lng: pos.lng, heading, tilt: TILT_GUIA };
    if (rafRef.current == null) rafRef.current = requestAnimationFrame(animarRef.current);
  }, [mapReady, modoGuia, posicion, zoomSeguir]);

  // 5) Tramo de navegación activo: polyline resaltada (cyan, gruesa) por encima
  //    de la ruta del día. Solo en modo guía (cuando viene rutaTramo).
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps;
    if (!g) return;
    const map = mapRef.current;
    const hayTramo = (rutaTramo?.length ?? 0) > 1;
    if (!hayTramo) {
      if (tramoPolylineRef.current) { tramoPolylineRef.current.setMap(null); tramoPolylineRef.current = null; }
      return;
    }
    const path = (rutaTramo as [number, number][]).map(([lat, lng]) => ({ lat, lng }));
    if (!tramoPolylineRef.current) {
      tramoPolylineRef.current = new g.Polyline({
        path, map, geodesic: false,
        strokeColor: '#06b6d4', strokeOpacity: 0.95, strokeWeight: 7, zIndex: 5,
      });
    } else {
      tramoPolylineRef.current.setPath(path);
    }
  }, [mapReady, rutaTramo]);

  // Limpieza al desmontar (salir de la pantalla): libera markers/polyline/círculo.
  useEffect(() => {
    return () => {
      if (rafRef.current != null) cancelAnimationFrame(rafRef.current);
      for (const m of markersRef.current) m.setMap(null);
      markersRef.current = [];
      depositoMarkerRef.current?.setMap(null);
      polylineRef.current?.setMap(null);
      tramoPolylineRef.current?.setMap(null);
      posMarkerRef.current?.setMap(null);
      posCircleRef.current?.setMap(null);
    };
  }, []);

  const esFull = altura === 'full';

  if (error) {
    return (
      <div className={`flex items-center justify-center bg-gray-100 dark:bg-gray-800 text-sm text-red-600 dark:text-red-400 p-4 text-center ${esFull ? 'h-full w-full' : 'rounded-xl'}`} style={esFull ? undefined : { height: altura }}>
        <div><MapPin className="w-6 h-6 mx-auto mb-2" />No se pudo cargar el mapa. {error}</div>
      </div>
    );
  }

  return (
    <div className={`relative overflow-hidden ${esFull ? 'h-full w-full' : 'rounded-xl border dark:border-gray-700'}`} style={esFull ? undefined : { height: altura }}>
      <div ref={containerRef} className="absolute inset-0" />
      {(isLoading || !isLoaded) && (
        <div className="absolute inset-0 flex items-center justify-center bg-white/70 dark:bg-gray-900/60 text-sm text-gray-600 dark:text-gray-300">
          <Loader2 className="w-5 h-5 mr-2 animate-spin" />
          Cargando mapa…
        </div>
      )}
    </div>
  );
}
