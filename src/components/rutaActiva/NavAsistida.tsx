/**
 * NavAsistida — pantalla completa de navegación asistida in-app (Fase 1).
 *
 * Guía al chofer de su posición a la próxima parada SIN salir de la app:
 *  - mapa raster que sigue la posición (reusa MapaRutaGoogle),
 *  - banner grande de la próxima maniobra (texto Google es-419) + distancia,
 *  - voz que anuncia la maniobra al acercarse,
 *  - “Abrir en Maps” como fallback y “Salir” siempre a mano.
 *
 * Fase 1 = SIN recálculo ni snap-to-route: una llamada por tramo (useNavTramo),
 * y el avance de maniobra se calcula contra los puntos absolutos de cada paso.
 * El handoff a Google Maps queda como red de seguridad. La cámara tilteada
 * heading-up, el snap y el recálculo en desvío son Fase 2/3.
 */
import { useEffect, useMemo, useRef, useState } from 'react';
import { X, Volume2, VolumeX, Map as MapIcon } from 'lucide-react';
import MapaRutaGoogle from './MapaRutaGoogle';
import BannerManiobra from './BannerManiobra';
import { useNavTramo, type Coord } from '../../hooks/useNavTramo';
import type { UseNavegacionVozReturn } from '../../hooks/useNavegacionVoz';
import type { PosicionGps } from '../../hooks/useWatchPosition';
import type { ParadaMapa } from '../MapaRuta';
import { haversineMeters, formatDistancia } from '../../utils/geo';

/** Distancia (m) a la maniobra para considerarla pasada y avanzar de paso. */
const UMBRAL_AVANCE_M = 30;
/** Distancia (m) para el aviso anticipado de la maniobra. */
const UMBRAL_AVISO_M = 160;

export interface NavAsistidaProps {
  destino: Coord;
  destinoNombre: string;
  destinoDireccion?: string;
  posicion: PosicionGps | null;
  gpsConfiable: boolean;
  /** El geofence del contenedor detectó llegada → cerrar nav y volver a entregar. */
  llegaste: boolean;
  voz: UseNavegacionVozReturn;
  vozOn: boolean;
  onToggleVoz: () => void;
  /** Deep-link a Google Maps/búsqueda como fallback. */
  navUrlFallback: string;
  onSalir: () => void;
}

export default function NavAsistida({
  destino,
  destinoNombre,
  destinoDireccion,
  posicion,
  gpsConfiable,
  llegaste,
  voz,
  vozOn,
  onToggleVoz,
  navUrlFallback,
  onSalir,
}: NavAsistidaProps) {
  const { decir, callar } = voz;

  // Origen del tramo: la posición al iniciar (capturada una vez por destino).
  const [origen, setOrigen] = useState<Coord | null>(null);
  useEffect(() => {
    setOrigen(null);
  }, [destino.lat, destino.lng]);
  useEffect(() => {
    if (!origen && gpsConfiable && posicion) {
      setOrigen({ lat: posicion.lat, lng: posicion.lng });
    }
  }, [origen, gpsConfiable, posicion]);

  const tramo = useNavTramo(origen, destino, true);
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

  const distManiobra = useMemo<number | null>(() => {
    if (!gpsConfiable || !posicion || !pasoActual) return null;
    return haversineMeters({ lat: posicion.lat, lng: posicion.lng }, pasoActual.inicio);
  }, [gpsConfiable, posicion, pasoActual]);

  // Avance de paso + avisos por voz (Fase 1: contra el punto absoluto del paso).
  useEffect(() => {
    if (!gpsConfiable || !posicion || pasos.length === 0) return;
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
  }, [posicion, gpsConfiable, pasos, idx, vozOn, decir]);

  // Llegada: anunciar y volver a la pantalla de entrega.
  const salioRef = useRef(false);
  useEffect(() => {
    if (llegaste && !salioRef.current) {
      salioRef.current = true;
      if (vozOn) decir('Llegaste a destino', { forzar: true });
      const t = window.setTimeout(() => onSalir(), 1500);
      return () => window.clearTimeout(t);
    }
  }, [llegaste, vozOn, decir, onSalir]);

  // Cortar la voz al cerrar la navegación.
  useEffect(() => () => callar(), [callar]);

  const paradasMapa = useMemo<ParadaMapa[]>(
    () => [{
      lat: destino.lat,
      lng: destino.lng,
      orden: 1,
      titulo: destinoNombre,
      subtitulo: destinoDireccion,
      entregado: false,
    }],
    [destino.lat, destino.lng, destinoNombre, destinoDireccion],
  );

  const etaMin = tramo.duracionSegundos != null
    ? Math.max(1, Math.round(tramo.duracionSegundos / 60))
    : null;

  return (
    <div className="fixed inset-0 z-50 flex flex-col bg-gray-900">
      {/* Mapa de fondo */}
      <div className="absolute inset-0">
        <MapaRutaGoogle
          paradas={paradasMapa}
          deposito={null}
          altura="full"
          rutaReal={tramo.rutaTramo.length > 1 ? tramo.rutaTramo : null}
          posicion={gpsConfiable && posicion ? { lat: posicion.lat, lng: posicion.lng, accuracy: posicion.accuracy } : null}
          paradaActivaOrden={1}
          seguirPosicion={gpsConfiable && posicion != null}
        />
      </div>

      {/* Banner de maniobra (arriba) */}
      <div className="absolute inset-x-0 top-0 z-10 px-3 pt-[max(env(safe-area-inset-top),12px)]">
        <BannerManiobra
          maniobra={pasoActual?.maniobra ?? null}
          instruccion={pasoActual?.instruccion ?? null}
          distanciaMetros={distManiobra}
          cargando={tramo.cargando}
          error={tramo.error}
        />
        {!gpsConfiable && !tramo.error && (
          <div className="mt-2 rounded-xl bg-amber-500 px-3 py-2 text-sm font-medium text-white shadow-lg">
            Buscando señal GPS… mantené el celu a la vista.
          </div>
        )}
      </div>

      {/* Barra inferior: destino + ETA + acciones */}
      <div className="absolute inset-x-0 bottom-0 z-10 px-3 pb-[max(env(safe-area-inset-bottom),12px)] pt-3">
        <div className="rounded-2xl bg-white/95 p-3 shadow-xl backdrop-blur dark:bg-gray-800/95">
          <div className="flex items-center justify-between gap-3">
            <div className="min-w-0">
              <p className="truncate font-semibold text-gray-900 dark:text-white">{destinoNombre}</p>
              <p className="text-xs text-gray-500 dark:text-gray-400">
                {etaMin != null && tramo.distanciaMetros != null
                  ? `≈ ${etaMin} min · ${formatDistancia(tramo.distanciaMetros)}`
                  : 'Calculando…'}
              </p>
            </div>
            <button
              onClick={onToggleVoz}
              className={`flex h-11 w-11 flex-shrink-0 items-center justify-center rounded-full transition-colors ${
                vozOn ? 'bg-blue-600 text-white' : 'bg-gray-200 text-gray-500 dark:bg-gray-700 dark:text-gray-300'
              }`}
              aria-label={vozOn ? 'Silenciar voz' : 'Activar voz'}
            >
              {vozOn ? <Volume2 className="h-5 w-5" /> : <VolumeX className="h-5 w-5" />}
            </button>
          </div>

          <div className="mt-3 grid grid-cols-2 gap-2">
            <a
              href={navUrlFallback}
              target="_blank"
              rel="noopener noreferrer"
              className="flex min-h-[48px] items-center justify-center gap-2 rounded-xl bg-gray-100 text-sm font-semibold text-gray-700 active:bg-gray-200 dark:bg-gray-700 dark:text-gray-200"
            >
              <MapIcon className="h-4 w-4" />
              Abrir en Maps
            </a>
            <button
              onClick={onSalir}
              className="flex min-h-[48px] items-center justify-center gap-2 rounded-xl bg-red-50 text-sm font-semibold text-red-700 active:bg-red-100 dark:bg-red-900/30 dark:text-red-300"
            >
              <X className="h-4 w-4" />
              Salir
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}
