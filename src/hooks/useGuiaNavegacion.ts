/**
 * useGuiaNavegacion — lógica de la guía giro-a-giro de la pantalla Ruta Activa.
 *
 * Extrae lo que antes vivía en NavAsistida (el overlay full-screen): pide el
 * tramo a la próxima parada, avanza de maniobra, canta los avisos por voz y
 * expone la maniobra actual/siguiente para el banner. Ahora la guía CONVIVE con
 * el mapa principal y el sheet del pedido (no es una pantalla aparte): este hook
 * solo produce el estado de guía; el contenedor decide cuándo está `guiando` y
 * renderiza el banner sobre el mapa.
 *
 * Fase 1 (asistida): una llamada por tramo, sin snap ni recálculo. El snap-to-
 * route + recálculo al desviarse + look-ahead se montan sobre `pasoSiguiente` y
 * `rutaTramo` que este hook ya expone (Fase C).
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavTramo, type Coord, type PasoNav } from './useNavTramo';
import type { PosicionGps } from './useWatchPosition';
import type { UseNavegacionVozReturn } from './useNavegacionVoz';
import type { LatLngTuple } from '../utils/polyline';
import { haversineMeters } from '../utils/geo';

/** Distancia (m) a la maniobra para considerarla pasada y avanzar de paso. */
const UMBRAL_AVANCE_M = 30;
/** Distancia (m) para el aviso anticipado de la maniobra. */
const UMBRAL_AVISO_M = 160;

export interface UseGuiaNavegacionParams {
  destino: Coord | null;
  posicion: PosicionGps | null;
  gpsConfiable: boolean;
  /** El geofence del contenedor detectó llegada a la parada activa. */
  llegaste: boolean;
  /** ¿La guía está activa? Cuando es false el hook queda inerte. */
  guiando: boolean;
  vozOn: boolean;
  voz: UseNavegacionVozReturn;
}

export interface UseGuiaNavegacionReturn {
  pasoActual: PasoNav | null;
  /** Maniobra siguiente (look-ahead) para anticipar giros encadenados. */
  pasoSiguiente: PasoNav | null;
  /** Distancia (m) a la maniobra actual. */
  distManiobra: number | null;
  /** Geometría del tramo decodificada (para dibujarlo resaltado en el mapa). */
  rutaTramo: LatLngTuple[];
  cargando: boolean;
  error: string | null;
}

export function useGuiaNavegacion({
  destino,
  posicion,
  gpsConfiable,
  llegaste,
  guiando,
  vozOn,
  voz,
}: UseGuiaNavegacionParams): UseGuiaNavegacionReturn {
  const { decir, callar } = voz;

  // Origen del tramo: la posición al iniciar la guía, capturada una vez por
  // destino. Se resetea al cambiar de parada o al apagar la guía.
  const [origen, setOrigen] = useState<Coord | null>(null);
  useEffect(() => {
    setOrigen(null);
  }, [destino?.lat, destino?.lng, guiando]);
  useEffect(() => {
    if (guiando && !origen && gpsConfiable && posicion) {
      setOrigen({ lat: posicion.lat, lng: posicion.lng });
    }
  }, [guiando, origen, gpsConfiable, posicion]);

  const tramo = useNavTramo(origen, destino, guiando && !!destino);
  const { pasos } = tramo;

  // Paso (maniobra) actual y avisos ya dichos por paso.
  const [idx, setIdx] = useState(0);
  const anunciadosRef = useRef<Set<number>>(new Set());
  useEffect(() => {
    // Saltear el "DEPART" inicial: arrancar en la primera maniobra real.
    const start = pasos.length > 1 && pasos[0]?.maniobra === 'DEPART' ? 1 : 0;
    setIdx(start);
    anunciadosRef.current = new Set();
  }, [pasos]);

  const pasoActual = pasos[idx] ?? null;
  const pasoSiguiente = pasos[idx + 1] ?? null;

  const distManiobra = useMemo<number | null>(() => {
    if (!gpsConfiable || !posicion || !pasoActual) return null;
    return haversineMeters({ lat: posicion.lat, lng: posicion.lng }, pasoActual.inicio);
  }, [gpsConfiable, posicion, pasoActual]);

  // Avance de paso + avisos por voz (contra el punto absoluto de cada paso).
  useEffect(() => {
    if (!guiando || !gpsConfiable || !posicion || pasos.length === 0) return;
    const paso = pasos[idx];
    if (!paso) return;
    const dist = haversineMeters({ lat: posicion.lat, lng: posicion.lng }, paso.inicio);
    const key150 = idx * 1000 + 150;
    const key30 = idx * 1000 + 30;

    if (vozOn) {
      if (dist <= UMBRAL_AVANCE_M && !anunciadosRef.current.has(key30)) {
        anunciadosRef.current.add(key30);
        anunciadosRef.current.add(key150);
        decir(paso.instruccion, { forzar: true });
      } else if (dist <= UMBRAL_AVISO_M && !anunciadosRef.current.has(key150)) {
        anunciadosRef.current.add(key150);
        const redonda = Math.max(10, Math.round(dist / 10) * 10);
        decir(`En ${redonda} metros, ${paso.instruccion}`);
      }
    }

    if (dist <= UMBRAL_AVANCE_M && idx < pasos.length - 1) {
      setIdx(i => (i < pasos.length - 1 ? i + 1 : i));
    }
  }, [guiando, posicion, gpsConfiable, pasos, idx, vozOn, decir]);

  // Anuncio de llegada (una vez mientras se guía).
  const llegadaRef = useRef(false);
  useEffect(() => {
    if (!guiando) {
      llegadaRef.current = false;
      return;
    }
    if (llegaste && !llegadaRef.current) {
      llegadaRef.current = true;
      if (vozOn) decir('Llegaste a destino', { forzar: true });
    }
  }, [guiando, llegaste, vozOn, decir]);

  // Cortar la voz al apagar la guía.
  useEffect(() => {
    if (!guiando) callar();
  }, [guiando, callar]);

  return {
    pasoActual,
    pasoSiguiente,
    distManiobra,
    rutaTramo: tramo.rutaTramo,
    cargando: tramo.cargando,
    error: tramo.error,
  };
}
