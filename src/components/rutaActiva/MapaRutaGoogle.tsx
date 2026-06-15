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
import type { MapaRutaProps } from '../MapaRuta';

const FALLBACK_CENTER = { lat: -26.8083, lng: -65.2176 };

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

export default function MapaRutaGoogle({
  paradas,
  deposito = null,
  altura = 280,
  posicion = null,
  paradaActivaOrden = null,
  onParadaTap,
  seguirPosicion = false,
  rutaReal = null,
}: MapaRutaProps): React.ReactElement {
  const { isLoaded, isLoading, error } = useGoogleMaps();
  const containerRef = useRef<HTMLDivElement | null>(null);
  const mapRef = useRef<google.maps.Map | null>(null);
  const markersRef = useRef<google.maps.Marker[]>([]);
  const depositoMarkerRef = useRef<google.maps.Marker | null>(null);
  const polylineRef = useRef<google.maps.Polyline | null>(null);
  const posMarkerRef = useRef<google.maps.Marker | null>(null);
  const posCircleRef = useRef<google.maps.Circle | null>(null);
  const fitSignatureRef = useRef<string>('');
  const [mapReady, setMapReady] = useState(false);

  // 1) Inicializar el mapa una sola vez.
  useEffect(() => {
    if (!isLoaded || !containerRef.current || mapRef.current) return;
    const g = (window.google as unknown as { maps: typeof google.maps } | undefined)?.maps;
    if (!g) return;
    mapRef.current = new g.Map(containerRef.current, {
      center: deposito ?? FALLBACK_CENTER,
      zoom: 13,
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
    if (!posMarkerRef.current) {
      posMarkerRef.current = new g.Marker({ position: pos, map, icon: circleSymbol('#3b82f6', 6), zIndex: 2000 });
    } else {
      posMarkerRef.current.setPosition(pos);
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
  }, [mapReady, posicion]);

  // 4) Encuadre dinámico: seguir la posición propia o centrar en la parada activa.
  useEffect(() => {
    if (!mapReady || !mapRef.current) return;
    const map = mapRef.current;
    if (seguirPosicion && posicion) {
      map.panTo({ lat: posicion.lat, lng: posicion.lng });
      return;
    }
    if (paradaActivaOrden != null) {
      const activa = paradas.find(p => p.orden === paradaActivaOrden);
      if (activa) map.panTo({ lat: activa.lat, lng: activa.lng });
    }
  }, [mapReady, seguirPosicion, posicion, paradaActivaOrden, paradas]);

  // Limpieza al desmontar (salir de la pantalla): libera markers/polyline/círculo.
  useEffect(() => {
    return () => {
      for (const m of markersRef.current) m.setMap(null);
      markersRef.current = [];
      depositoMarkerRef.current?.setMap(null);
      polylineRef.current?.setMap(null);
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
