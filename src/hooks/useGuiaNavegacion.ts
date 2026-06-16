/**
 * useGuiaNavegacion — lógica de la guía giro-a-giro de la pantalla Ruta Activa.
 *
 * Produce el estado de guía (maniobra actual/siguiente, distancia, geometría)
 * que el contenedor renderiza como banner sobre el mapa principal (la guía
 * convive con el sheet del pedido; no es una pantalla aparte).
 *
 * Fase C — precisión:
 *  - SNAP-TO-ROUTE: proyecta el GPS sobre la polyline del tramo (`navSnap`) para
 *    medir la distancia a la maniobra A LO LARGO de la ruta (no en línea recta) y
 *    avanzar de paso por posición sobre la ruta.
 *  - RECÁLCULO al desviarse: si la distancia perpendicular a la ruta supera el
 *    umbral por varios fixes seguidos, recaptura la posición como nuevo origen y
 *    pide el tramo de nuevo (bump de `recomputeNonce` en useNavTramo).
 *  - LOOK-AHEAD: expone `pasoSiguiente` para anticipar el giro encadenado.
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import { useNavTramo, type Coord, type PasoNav } from './useNavTramo';
import type { PosicionGps } from './useWatchPosition';
import type { UseNavegacionVozReturn } from './useNavegacionVoz';
import type { LatLngTuple } from '../utils/polyline';
import { haversineMeters } from '../utils/geo';
import { construirSnapper, snapEnRuta, distanciaEnRutaDe, type Snapper } from '../utils/navSnap';

/** Distancia (m) a la maniobra para considerarla pasada y avanzar de paso. */
const UMBRAL_AVANCE_M = 30;
/** Distancia (m) para el aviso anticipado de la maniobra. */
const UMBRAL_AVISO_M = 160;
/** Desvío perpendicular (m) a la ruta para considerarse fuera de ruta. */
const UMBRAL_OFFROUTE_M = 45;
/** Fixes consecutivos fuera de ruta antes de recalcular (filtra bandazos del GPS). */
const OFFROUTE_FIXES = 3;

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
  /** Distancia (m) a la maniobra actual, a lo largo de la ruta. */
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

  // Origen del tramo (posición al iniciar) + nonce para forzar recálculo.
  const [origen, setOrigen] = useState<Coord | null>(null);
  const [recomputeNonce, setRecomputeNonce] = useState(0);
  useEffect(() => {
    setOrigen(null);
    setRecomputeNonce(0);
  }, [destino?.lat, destino?.lng, guiando]);
  useEffect(() => {
    if (guiando && !origen && gpsConfiable && posicion) {
      setOrigen({ lat: posicion.lat, lng: posicion.lng });
    }
  }, [guiando, origen, gpsConfiable, posicion]);

  const tramo = useNavTramo(origen, destino, guiando && !!destino, recomputeNonce);
  const { pasos, rutaTramo } = tramo;

  // Snapper + distancia en ruta de cada maniobra: una vez por tramo.
  const snapper = useMemo<Snapper | null>(
    () => (rutaTramo.length >= 2 ? construirSnapper(rutaTramo) : null),
    [rutaTramo],
  );
  const pasosDist = useMemo<number[]>(
    () => (snapper ? pasos.map(p => distanciaEnRutaDe(snapper, p.inicio)) : []),
    [snapper, pasos],
  );
  // Primera maniobra "real" (saltea el DEPART inicial).
  const idxBase = pasos.length > 1 && pasos[0]?.maniobra === 'DEPART' ? 1 : 0;

  // Estado derivado del snap (maniobra activa + distancia), por tick de GPS.
  const [guia, setGuia] = useState<{ idx: number; dist: number | null }>({ idx: 0, dist: null });
  const hintRef = useRef(0);
  const offrouteRef = useRef(0);
  const recalcRef = useRef(false);
  const anunciadosRef = useRef<Set<string>>(new Set());

  // Reset al cambiar de tramo (nuevo snapper).
  useEffect(() => {
    hintRef.current = 0;
    offrouteRef.current = 0;
    recalcRef.current = false;
    anunciadosRef.current = new Set();
    setGuia({ idx: idxBase, dist: null });
  }, [snapper, idxBase]);

  // Tick: snap → maniobra actual + distancia, avisos de voz, detección de desvío.
  useEffect(() => {
    if (!guiando || !gpsConfiable || !posicion || pasos.length === 0) return;
    const pos = { lat: posicion.lat, lng: posicion.lng };

    let idx: number;
    let dist: number | null;

    if (snapper && pasosDist.length === pasos.length) {
      const snap = snapEnRuta(snapper, pos, hintRef.current);
      hintRef.current = snap.segmentIndex;

      // Maniobra actual = la primera (≥ idxBase) que todavía no pasamos.
      idx = pasos.length - 1;
      for (let i = idxBase; i < pasos.length; i++) {
        if (pasosDist[i] >= snap.distanciaEnRuta - UMBRAL_AVANCE_M) { idx = i; break; }
      }
      dist = Math.max(0, pasosDist[idx] - snap.distanciaEnRuta);

      // Desvío sostenido → recálculo del tramo desde la posición actual.
      if (snap.perpendicularM > UMBRAL_OFFROUTE_M) {
        offrouteRef.current += 1;
        if (offrouteRef.current >= OFFROUTE_FIXES && !recalcRef.current) {
          recalcRef.current = true;
          setOrigen(pos);
          setRecomputeNonce(n => n + 1);
        }
      } else {
        offrouteRef.current = 0;
      }
    } else {
      // Sin snapper (tramo cargando): fallback a distancia recta al paso base.
      idx = idxBase;
      dist = haversineMeters(pos, pasos[idxBase].inicio);
    }

    setGuia(prev => (prev.idx === idx && prev.dist === dist ? prev : { idx, dist }));

    // Avisos de voz por umbral, una vez por maniobra.
    if (vozOn && dist != null) {
      const paso = pasos[idx];
      const k150 = `${idx}:150`;
      const k30 = `${idx}:30`;
      if (dist <= UMBRAL_AVANCE_M && !anunciadosRef.current.has(k30)) {
        anunciadosRef.current.add(k30);
        anunciadosRef.current.add(k150);
        decir(paso.instruccion, { forzar: true });
      } else if (dist <= UMBRAL_AVISO_M && !anunciadosRef.current.has(k150)) {
        anunciadosRef.current.add(k150);
        const redonda = Math.max(10, Math.round(dist / 10) * 10);
        decir(`En ${redonda} metros, ${paso.instruccion}`);
      }
    }
  }, [guiando, posicion, gpsConfiable, snapper, pasos, pasosDist, idxBase, vozOn, decir]);

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
    pasoActual: pasos[guia.idx] ?? null,
    pasoSiguiente: pasos[guia.idx + 1] ?? null,
    distManiobra: guia.dist,
    rutaTramo,
    cargando: tramo.cargando,
    error: tramo.error,
  };
}
