/**
 * useNavTramo — pide a la edge function `optimizar-ruta` (modo navegar_tramo)
 * la guía giro-a-giro de UN tramo: de la posición actual a la próxima parada.
 *
 * Fase 1 (navegación asistida): una sola llamada por tramo, SIN recálculo. El
 * origen se captura una vez (la posición al iniciar el tramo) y no se refetchea
 * al moverse; el avance de maniobra se calcula client-side contra los puntos
 * absolutos de cada paso. La query se cachea por destino (`staleTime: Infinity`)
 * para no gastar llamadas de más. `refetch` queda expuesto para la Fase 2
 * (recálculo al desviarse).
 */
import { useMemo } from 'react';
import { useQuery, keepPreviousData } from '@tanstack/react-query';
import { supabase } from './supabase/base';
import { decodePolyline, type LatLngTuple } from '../utils/polyline';

export interface Coord {
  lat: number;
  lng: number;
}

export interface PasoNav {
  /** Enum de maniobra de Google (TURN_RIGHT, ROUNDABOUT_LEFT, …) o "". */
  maniobra: string;
  /** Texto de la instrucción ya localizado (es-419). */
  instruccion: string;
  distancia_metros: number;
  duracion_segundos: number;
  polyline: string;
  /** Punto donde ocurre la maniobra. */
  inicio: Coord;
  fin: Coord;
}

interface TramoNavResponse {
  success?: boolean;
  pasos?: PasoNav[];
  polyline?: string;
  distancia_metros?: number;
  duracion_segundos?: number;
  error?: string;
  mensaje?: string;
}

async function fetchTramo(origen: Coord, destino: Coord): Promise<TramoNavResponse> {
  const { data, error } = await supabase.functions.invoke('optimizar-ruta', {
    body: { mode: 'navegar_tramo', origen, destino },
  });
  if (error) throw new Error(error.message);
  const r = (data ?? {}) as TramoNavResponse;
  if (r.error) throw new Error(r.mensaje || r.error);
  return r;
}

export interface UseNavTramoReturn {
  pasos: PasoNav[];
  /** Geometría del tramo decodificada para dibujar la ruta. */
  rutaTramo: LatLngTuple[];
  distanciaMetros: number | null;
  duracionSegundos: number | null;
  cargando: boolean;
  error: string | null;
  refetch: () => void;
}

export function useNavTramo(
  origen: Coord | null,
  destino: Coord | null,
  enabled: boolean,
  recomputeNonce = 0,
): UseNavTramoReturn {
  // La query se keyea por destino + `recomputeNonce`: una llamada por tramo, y
  // los cambios de origen al moverse NO re-fetchean (la key no cambia). Para
  // recalcular al desviarse, el caller bumpea `recomputeNonce` tras actualizar
  // el origen → la key cambia y se vuelve a pedir con el origen nuevo (capturado
  // en el closure del queryFn). keepPreviousData evita el flicker del banner.
  const query = useQuery({
    queryKey: ['nav-tramo', destino?.lat ?? null, destino?.lng ?? null, recomputeNonce],
    queryFn: () => fetchTramo(origen as Coord, destino as Coord),
    enabled: enabled && !!origen && !!destino,
    staleTime: Infinity,
    retry: 1,
    refetchOnWindowFocus: false,
    placeholderData: keepPreviousData,
  });

  const polyline = query.data?.polyline;
  const rutaTramo = useMemo<LatLngTuple[]>(
    () => (polyline ? decodePolyline(polyline) : []),
    [polyline],
  );

  return {
    pasos: query.data?.pasos ?? [],
    rutaTramo,
    distanciaMetros: query.data?.distancia_metros ?? null,
    duracionSegundos: query.data?.duracion_segundos ?? null,
    cargando: query.isFetching,
    error: query.error instanceof Error ? query.error.message : null,
    refetch: () => { void query.refetch(); },
  };
}
