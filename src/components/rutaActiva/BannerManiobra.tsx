/**
 * BannerManiobra — banner grande de la próxima maniobra en el modo navegación.
 * Ícono de la maniobra (mapeo del enum de Google) + distancia + instrucción.
 * Pensado para leerse de un vistazo con el celu montado en el auto.
 */
import {
  ArrowUp, ArrowRight, ArrowLeft, ArrowUpRight, ArrowUpLeft,
  CornerUpRight, CornerUpLeft, RotateCw, RotateCcw, Navigation, Ship, Flag, Loader2,
  type LucideIcon,
} from 'lucide-react';
import { formatDistancia } from '../../utils/geo';

/** Mapeo del enum `maneuver` de Routes API a íconos. */
const ICONOS: Record<string, LucideIcon> = {
  DEPART: Navigation,
  STRAIGHT: ArrowUp,
  NAME_CHANGE: ArrowUp,
  MERGE: ArrowUp,
  TURN_RIGHT: ArrowRight,
  TURN_LEFT: ArrowLeft,
  TURN_SLIGHT_RIGHT: ArrowUpRight,
  TURN_SLIGHT_LEFT: ArrowUpLeft,
  TURN_SHARP_RIGHT: CornerUpRight,
  TURN_SHARP_LEFT: CornerUpLeft,
  RAMP_RIGHT: ArrowUpRight,
  RAMP_LEFT: ArrowUpLeft,
  FORK_RIGHT: ArrowUpRight,
  FORK_LEFT: ArrowUpLeft,
  ROUNDABOUT_RIGHT: RotateCw,
  ROUNDABOUT_LEFT: RotateCcw,
  UTURN_RIGHT: RotateCw,
  UTURN_LEFT: RotateCcw,
  FERRY: Ship,
  FERRY_TRAIN: Ship,
  LLEGADA: Flag,
};

export interface BannerManiobraProps {
  maniobra: string | null;
  instruccion: string | null;
  /** Distancia a la maniobra, en metros. */
  distanciaMetros: number | null;
  /** Look-ahead: maniobra siguiente (se muestra como "Luego …"). */
  maniobraSiguiente?: string | null;
  instruccionSiguiente?: string | null;
  cargando?: boolean;
  error?: string | null;
}

export default function BannerManiobra({
  maniobra,
  instruccion,
  distanciaMetros,
  maniobraSiguiente = null,
  instruccionSiguiente = null,
  cargando = false,
  error = null,
}: BannerManiobraProps) {
  if (error) {
    return (
      <div className="rounded-2xl bg-red-600 px-4 py-3 text-white shadow-xl">
        <p className="text-sm font-semibold">No se pudo trazar la ruta</p>
        <p className="text-xs opacity-90">{error} — usá “Abrir en Maps”.</p>
      </div>
    );
  }

  if (cargando || !instruccion) {
    return (
      <div className="flex items-center gap-3 rounded-2xl bg-gray-900/95 px-4 py-3 text-white shadow-xl">
        <Loader2 className="h-6 w-6 flex-shrink-0 animate-spin" />
        <p className="text-base font-medium">Calculando ruta…</p>
      </div>
    );
  }

  const Icono = ICONOS[maniobra ?? ''] ?? Navigation;
  const IconoSiguiente = instruccionSiguiente ? (ICONOS[maniobraSiguiente ?? ''] ?? Navigation) : null;

  return (
    <div className="rounded-2xl bg-gray-900/95 px-4 py-3.5 text-white shadow-xl ring-1 ring-white/10 backdrop-blur">
      <div className="flex items-center gap-3.5">
        <div className="flex h-16 w-16 flex-shrink-0 items-center justify-center rounded-2xl bg-blue-600">
          <Icono className="h-9 w-9" strokeWidth={2.5} />
        </div>
        <div className="min-w-0 flex-1">
          {distanciaMetros != null && (
            <p className="text-3xl font-extrabold leading-none tabular-nums">
              {formatDistancia(distanciaMetros)}
            </p>
          )}
          <p className="mt-1 line-clamp-2 text-base font-medium leading-snug text-gray-100">
            {instruccion}
          </p>
        </div>
      </div>
      {IconoSiguiente && instruccionSiguiente && (
        <div className="mt-2.5 flex items-center gap-2 border-t border-white/10 pt-2 text-sm text-gray-300">
          <span className="flex-shrink-0 text-[11px] font-semibold uppercase tracking-wide text-gray-400">Luego</span>
          <IconoSiguiente className="h-4 w-4 flex-shrink-0 text-gray-300" />
          <span className="truncate">{instruccionSiguiente}</span>
        </div>
      )}
    </div>
  );
}
