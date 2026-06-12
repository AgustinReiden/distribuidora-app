/**
 * useWatchPosition — seguimiento continuo de la posición GPS del dispositivo.
 *
 * Envuelve navigator.geolocation.watchPosition con:
 *  - cleanup automático al desmontar o desactivar,
 *  - throttle de updates (el GPS puede emitir varias veces por segundo),
 *  - estado tipado (posición, error, soporte).
 *
 * Usado por la pantalla Ruta Activa del transportista (punto azul + geofence
 * de llegada) y, en fase 2, por el reporte de ubicación en vivo.
 *
 * Limitación PWA conocida: el watch solo corre con la app abierta en pantalla;
 * en background el navegador lo pausa.
 */
import { useEffect, useRef, useState } from 'react';

export interface PosicionGps {
  lat: number;
  lng: number;
  /** Precisión en metros reportada por el dispositivo */
  accuracy: number;
  /** Rumbo en grados (0 = norte) o null si el dispositivo no lo reporta */
  heading: number | null;
  /** Velocidad en m/s o null */
  speed: number | null;
  timestamp: number;
}

export interface UseWatchPositionReturn {
  posicion: PosicionGps | null;
  error: string | null;
  soportado: boolean;
}

export function useWatchPosition(activo = true, throttleMs = 4000): UseWatchPositionReturn {
  const [posicion, setPosicion] = useState<PosicionGps | null>(null);
  const [error, setError] = useState<string | null>(null);
  const ultimoUpdateRef = useRef<number>(0);
  const soportado = typeof navigator !== 'undefined' && 'geolocation' in navigator;

  useEffect(() => {
    if (!activo || !soportado) return;

    const watchId = navigator.geolocation.watchPosition(
      (pos) => {
        const ahora = Date.now();
        if (ahora - ultimoUpdateRef.current < throttleMs) return;
        ultimoUpdateRef.current = ahora;
        setError(null);
        setPosicion({
          lat: pos.coords.latitude,
          lng: pos.coords.longitude,
          accuracy: pos.coords.accuracy,
          heading: pos.coords.heading,
          speed: pos.coords.speed,
          timestamp: pos.timestamp,
        });
      },
      (err) => {
        const mensajes: Record<number, string> = {
          1: 'Permiso de ubicación denegado',
          2: 'Ubicación no disponible',
          3: 'Timeout obteniendo ubicación',
        };
        setError(mensajes[err.code] || 'Error de GPS');
      },
      { enableHighAccuracy: true, maximumAge: 5000, timeout: 15000 },
    );

    return () => navigator.geolocation.clearWatch(watchId);
  }, [activo, soportado, throttleMs]);

  return { posicion, error, soportado };
}
