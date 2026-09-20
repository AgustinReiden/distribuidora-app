/**
 * ModalConfigDigest — qué recibe cada admin en el resumen de Telegram y cuándo.
 *
 * Edita una fila de `bot_digest_config`. El estado es local hasta Guardar: se
 * puede prender y apagar sin que salga un mensaje a medio configurar.
 *
 * Tres reglas que la base también hace cumplir (CHECKs de la migración), acá
 * adelantadas para que el admin no se coma un error del servidor:
 *   - al menos un día;
 *   - al menos una sección;
 *   - hora entre 0 y 23.
 * Con "no recibir" tildado nada de eso importa y el formulario se deshabilita:
 * es la forma explícita de decir "a mí no me mandes".
 */
import { useMemo, useState, type ReactElement } from 'react';
import { AlertCircle } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import { DIAS_SEMANA, SECCIONES_DIGEST, formatHora } from '../../utils/digestSecciones';
import type {
  BotDigestConfig,
  GuardarConfigDigestInput,
} from '../../hooks/queries/useBotDigestConfig';

export interface ModalConfigDigestProps {
  config: BotDigestConfig;
  onClose: () => void;
  onGuardar: (input: GuardarConfigDigestInput) => Promise<void>;
}

const HORAS = Array.from({ length: 24 }, (_, h) => h);

export default function ModalConfigDigest({
  config,
  onClose,
  onGuardar,
}: ModalConfigDigestProps): ReactElement {
  const [activo, setActivo] = useState(config.activo);
  const [hora, setHora] = useState(config.hora_local);
  const [dias, setDias] = useState<number[]>(config.dias_semana);
  const [secciones, setSecciones] = useState<string[]>(config.secciones);
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const toggleDia = (iso: number): void => {
    setDias((prev) => (prev.includes(iso) ? prev.filter((d) => d !== iso) : [...prev, iso]));
  };

  const toggleSeccion = (key: string): void => {
    setSecciones((prev) => (prev.includes(key) ? prev.filter((s) => s !== key) : [...prev, key]));
  };

  // Con "no recibir" tildado, un día o sección de menos no bloquea nada: la
  // configuración se guarda igual y queda lista para cuando lo reactive.
  const problema = useMemo<string | null>(() => {
    if (!activo) return null;
    if (dias.length === 0) return 'Elegí al menos un día, o marcá "No recibir el resumen".';
    if (secciones.length === 0) {
      return 'Elegí al menos una sección, o marcá "No recibir el resumen".';
    }
    return null;
  }, [activo, dias, secciones]);

  const handleGuardar = async (): Promise<void> => {
    if (problema) return;
    setGuardando(true);
    setError(null);
    try {
      await onGuardar({
        perfil_id: config.perfil_id,
        activo,
        hora_local: hora,
        // Ordenados para que la fila de la base no dependa del orden de clic.
        dias_semana: [...dias].sort((a, b) => a - b),
        secciones: [...secciones].sort(),
      });
      onClose();
    } catch (err) {
      setError(err instanceof Error ? err.message : 'No se pudo guardar la configuración.');
      setGuardando(false);
    }
  };

  return (
    <ModalBase
      title={`Resumen de ${config.perfil_nombre ?? 'este usuario'}`}
      description="Qué le llega por Telegram y en qué momento."
      maxWidth="max-w-2xl"
      onClose={onClose}
    >
      <div className="space-y-6">
        {!config.configurado && (
          <p className="text-sm text-gray-600 dark:text-gray-400 bg-gray-50 dark:bg-gray-700/40 rounded-md px-3 py-2">
            Todavía no tiene una configuración propia: lo que ves es el default con el que
            viene recibiendo el resumen.
          </p>
        )}

        {/* Recibir o no */}
        <label className="flex items-start gap-3 cursor-pointer">
          <input
            type="checkbox"
            checked={!activo}
            onChange={(e) => setActivo(!e.target.checked)}
            className="mt-1 w-4 h-4 rounded border-gray-300 text-red-600 focus:ring-red-500"
          />
          <span>
            <span className="font-medium text-gray-800 dark:text-white">
              No recibir el resumen
            </span>
            <span className="block text-sm text-gray-500 dark:text-gray-400">
              Sigue pudiendo usar el bot normalmente; sólo deja de llegarle el mensaje
              automático.
            </span>
          </span>
        </label>

        <fieldset disabled={!activo} className={activo ? '' : 'opacity-50'}>
          {/* Hora */}
          <div className="mb-5">
            <label
              htmlFor="config-digest-hora"
              className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1"
            >
              Hora
            </label>
            <select
              id="config-digest-hora"
              value={hora}
              onChange={(e) => setHora(Number(e.target.value))}
              className="w-40 px-3 py-2 border dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-800 dark:text-white"
            >
              {HORAS.map((h) => (
                <option key={h} value={h}>
                  {formatHora(h)}
                </option>
              ))}
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              Hora de Argentina. El resumen es siempre del día anterior.
            </p>
          </div>

          {/* Días */}
          <div className="mb-5">
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-2">
              Días
            </span>
            <div className="flex flex-wrap gap-2">
              {DIAS_SEMANA.map((d) => {
                const elegido = dias.includes(d.iso);
                return (
                  <button
                    key={d.iso}
                    type="button"
                    onClick={() => toggleDia(d.iso)}
                    aria-pressed={elegido}
                    aria-label={d.largo}
                    className={`px-3 py-1.5 rounded-full text-sm font-medium transition-colors ${
                      elegido
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-100 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-600'
                    }`}
                  >
                    {d.corto}
                  </button>
                );
              })}
            </div>
          </div>

          {/* Secciones */}
          <div>
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-2">
              Secciones del mensaje
            </span>
            <div className="grid sm:grid-cols-2 gap-2">
              {SECCIONES_DIGEST.map((s) => (
                <label
                  key={s.key}
                  className="flex items-start gap-2 p-2 rounded-md border dark:border-gray-700 cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-700/50"
                >
                  <input
                    type="checkbox"
                    checked={secciones.includes(s.key)}
                    onChange={() => toggleSeccion(s.key)}
                    className="mt-1 w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
                  />
                  <span>
                    <span className="block text-sm font-medium text-gray-800 dark:text-white">
                      {s.label}
                    </span>
                    <span className="block text-xs text-gray-500 dark:text-gray-400">
                      {s.detalle}
                    </span>
                  </span>
                </label>
              ))}
            </div>
          </div>
        </fieldset>

        {(problema || error) && (
          <p
            role="alert"
            className="flex items-start gap-2 text-sm text-red-600 dark:text-red-400"
          >
            <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" aria-hidden="true" />
            {problema ?? error}
          </p>
        )}

        <div className="flex justify-end gap-2 pt-2 border-t dark:border-gray-700">
          <Button
            type="button"
            onClick={onClose}
            disabled={guardando}
            variant="ghost"
            size="md"
          >
            Cancelar
          </Button>
          <Button
            type="button"
            onClick={handleGuardar}
            disabled={guardando || problema !== null}
            loading={guardando}
            variant="primary"
            size="md"
          >
            Guardar
          </Button>
        </div>
      </div>
    </ModalBase>
  );
}
