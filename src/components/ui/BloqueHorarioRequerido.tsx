import { useState, memo } from 'react';
import { AlertCircle, Loader2 } from 'lucide-react';
import FranjasHorariasEditor from './FranjasHorariasEditor';
import DiasAtencionSelector from './DiasAtencionSelector';
import {
  convertirHorarioInicial,
  serializarFranjas,
  validarFranjas,
} from '../../utils/horariosCliente';
import type { FranjaHoraria } from '../../utils/horariosCliente';

/** Patch que se persiste sobre el cliente. */
export interface PatchHorarioCliente {
  horarios_atencion?: string;
  dias_atencion?: string | null;
  sin_horario_fijo?: boolean;
}

export interface BloqueHorarioRequeridoProps {
  /** Nombre a mostrar (solo para el copy). */
  nombreCliente: string;
  /** Texto ya cargado en `horarios_atencion`, si lo hay (puede ser legacy no parseable). */
  horarioActual?: string | null;
  /** Días ya cargados (bitmask), para no perderlos al guardar. */
  diasActuales?: string | null;
  /** Persiste el patch. Debe rechazar si falla para que se muestre el error. */
  onGuardar: (patch: PatchHorarioCliente) => Promise<void>;
}

/**
 * Bloque que pide el horario de atención de un cliente que no lo tiene, para
 * cargarlo sin salir del modal de pedido.
 *
 * Va montado con `key={cliente.id}` para que el estado del editor se reinicie
 * al cambiar de cliente sin necesidad de un efecto de sincronización.
 *
 * El escape ("no atiende con horario fijo") no es una concesión: hay clientes
 * que genuinamente no tienen horario (puestos de feria, kioscos que abren
 * cuando pueden). Sin él, el aviso reaparecería en cada pedido de ese cliente
 * y los preventistas aprenderían a ignorarlo.
 */
const BloqueHorarioRequerido = memo(function BloqueHorarioRequerido({
  nombreCliente,
  horarioActual,
  diasActuales,
  onGuardar,
}: BloqueHorarioRequeridoProps) {
  // Si había texto libre legacy lo mostramos como ayuda para que el preventista
  // lo traduzca a franjas en vez de tipearlo de cero.
  const legacy = convertirHorarioInicial(horarioActual).sinReconocer;

  const [franjas, setFranjas] = useState<FranjaHoraria[]>([{ apertura: '', cierre: '' }]);
  const [dias, setDias] = useState<string | null>(diasActuales ?? null);
  const [guardando, setGuardando] = useState<boolean>(false);
  const [error, setError] = useState<string>('');

  const persistir = async (patch: PatchHorarioCliente): Promise<void> => {
    setGuardando(true);
    try {
      await onGuardar(patch);
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo guardar el horario.');
    }
    setGuardando(false);
  };

  const handleGuardar = async (): Promise<void> => {
    const serializado = serializarFranjas(franjas);
    if (!serializado) {
      setError('Cargá al menos una franja completa (apertura y cierre).');
      return;
    }
    if (!validarFranjas(franjas).valido) {
      setError('Revisá los horarios: la apertura debe ser anterior al cierre y las franjas no pueden superponerse.');
      return;
    }
    setError('');
    await persistir({ horarios_atencion: serializado, dias_atencion: dias });
  };

  return (
    <div
      role="alert"
      className="border border-amber-300 dark:border-amber-700 rounded-lg p-3 space-y-3 bg-amber-50 dark:bg-amber-900/20"
    >
      <div className="flex items-start gap-2">
        <AlertCircle className="w-5 h-5 text-amber-600 dark:text-amber-400 shrink-0 mt-0.5" />
        <div>
          <p className="font-medium text-sm text-amber-900 dark:text-amber-200">
            Falta el horario de {nombreCliente}
          </p>
          <p className="text-xs text-amber-800 dark:text-amber-300 mt-0.5">
            Cargalo acá para poder confirmar el pedido. Se usa para armar la ruta y no
            mandar al repartidor cuando el local está cerrado.
          </p>
          {legacy.length > 0 && (
            <p className="text-xs text-amber-800 dark:text-amber-300 mt-1">
              Está anotado como texto libre: «{legacy.join(' y ')}». Pasalo a franjas.
            </p>
          )}
        </div>
      </div>

      <FranjasHorariasEditor franjas={franjas} onChange={setFranjas} />
      <DiasAtencionSelector valor={dias} onChange={setDias} />

      {error && (
        <p className="text-sm text-red-600 bg-red-50 dark:bg-red-900/20 dark:text-red-400 px-3 py-2 rounded-lg">
          {error}
        </p>
      )}

      <div className="flex flex-col sm:flex-row gap-2">
        <button
          type="button"
          onClick={handleGuardar}
          disabled={guardando}
          className="flex-1 py-2 bg-amber-600 text-white font-medium rounded-lg hover:bg-amber-700 disabled:bg-amber-400 disabled:cursor-not-allowed flex items-center justify-center gap-2"
        >
          {guardando && <Loader2 className="w-4 h-4 animate-spin" />}
          Guardar horario
        </button>
        <button
          type="button"
          onClick={() => persistir({ sin_horario_fijo: true })}
          disabled={guardando}
          className="px-3 py-2 text-sm font-medium text-amber-800 dark:text-amber-300 hover:bg-amber-100 dark:hover:bg-amber-900/40 rounded-lg disabled:opacity-60 disabled:cursor-not-allowed"
        >
          No atiende con horario fijo
        </button>
      </div>
    </div>
  );
});

export default BloqueHorarioRequerido;
