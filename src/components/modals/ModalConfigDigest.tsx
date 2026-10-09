/**
 * ModalConfigDigest — qué recibe cada admin o preventista en el resumen de
 * Telegram y cuándo.
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
 *
 * Cada rol tiene sus secciones (mig 311): al preventista sólo se le ofrece lo
 * suyo, y la base rechaza igual una sección ajena. Y al preventista, a
 * diferencia del admin, sin configuración no le llega nada: hay que activarlo.
 *
 * Mig 325: el preventista tiene además un segundo bloque, el aviso semanal de
 * clientes atrasados, con su propio día y hora. Se guarda con otra RPC; al
 * admin (su propia fila) no se le ofrece.
 */
import { useMemo, useState, type ReactElement } from 'react';
import { AlertCircle } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import { DIAS_SEMANA, formatHora, seccionesParaRol } from '../../utils/digestSecciones';
import type {
  BotDigestConfig,
  GuardarAvisoAtrasadosInput,
  GuardarConfigDigestInput,
} from '../../hooks/queries/useBotDigestConfig';

export interface ModalConfigDigestProps {
  config: BotDigestConfig;
  onClose: () => void;
  onGuardar: (input: GuardarConfigDigestInput) => Promise<void>;
  /** Guarda el aviso de atrasados. Sólo se usa con preventistas. */
  onGuardarAviso?: (input: GuardarAvisoAtrasadosInput) => Promise<void>;
}

// Lo mismo que devuelve la base para un preventista sin configuración propia.
const AVISO_DEFAULT = { activo: true, hora: 8, dias: [1] };

const HORAS = Array.from({ length: 24 }, (_, h) => h);

export default function ModalConfigDigest({
  config,
  onClose,
  onGuardar,
  onGuardarAviso,
}: ModalConfigDigestProps): ReactElement {
  const [activo, setActivo] = useState(config.activo);
  const [hora, setHora] = useState(config.hora_local);
  const [dias, setDias] = useState<number[]>(config.dias_semana);
  const esPreventista = config.rol === 'preventista';
  const avisoInicial = config.aviso_atrasados ?? AVISO_DEFAULT;
  const [avisoActivo, setAvisoActivo] = useState(avisoInicial.activo);
  const [avisoHora, setAvisoHora] = useState(avisoInicial.hora);
  const [avisoDias, setAvisoDias] = useState<number[]>(avisoInicial.dias);
  const opciones = useMemo(
    () => seccionesParaRol(config.rol, config.secciones_permitidas),
    [config.rol, config.secciones_permitidas],
  );
  // Una fila vieja con una sección que ya no es de su rol no se re-guarda: la
  // base la rechazaría y el admin no sabría por qué.
  const [secciones, setSecciones] = useState<string[]>(() =>
    config.secciones.filter((s) => opciones.some((o) => o.key === s)),
  );
  const [guardando, setGuardando] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const toggleDia = (iso: number): void => {
    setDias((prev) => (prev.includes(iso) ? prev.filter((d) => d !== iso) : [...prev, iso]));
  };

  const toggleAvisoDia = (iso: number): void => {
    setAvisoDias((prev) => (prev.includes(iso) ? prev.filter((d) => d !== iso) : [...prev, iso]));
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
      return 'Elegí al menos una opción de qué incluir, o marcá "No recibir el resumen".';
    }
    return null;
  }, [activo, dias, secciones]);

  const problemaAviso = useMemo<string | null>(() => {
    if (!esPreventista || !avisoActivo) return null;
    if (avisoDias.length === 0) {
      return 'Elegí al menos un día para el aviso de clientes atrasados, o destildá "Recibir el aviso".';
    }
    return null;
  }, [esPreventista, avisoActivo, avisoDias]);

  const handleGuardar = async (): Promise<void> => {
    if (problema || problemaAviso) return;
    setGuardando(true);
    setError(null);
    try {
      // El aviso va primero: el "Configuración guardada" lo da el handler del
      // resumen, y tiene que significar que se guardó todo.
      if (esPreventista && onGuardarAviso) {
        await onGuardarAviso({
          perfil_id: config.perfil_id,
          activo: avisoActivo,
          hora: avisoHora,
          dias: [...avisoDias].sort((a, b) => a - b),
        });
      }
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
      title={
        config.es_propio ? 'Tu resumen' : `Resumen de ${config.perfil_nombre ?? 'este usuario'}`
      }
      description={
        config.es_propio
          ? 'Qué te llega por Telegram y en qué momento.'
          : 'Qué le llega por Telegram y en qué momento.'
      }
      maxWidth="max-w-2xl"
      onClose={onClose}
    >
      <div className="space-y-6">
        {!config.configurado && (
          <p className="text-sm text-gray-600 dark:text-gray-400 bg-gray-50 dark:bg-gray-700/40 rounded-md px-3 py-2">
            {esPreventista
              ? 'Todavía no tiene una configuración propia: hoy no recibe ningún resumen. Destildá "No recibir el resumen" para activárselo.'
              : 'Todavía no tiene una configuración propia: lo que ves es el default con el que viene recibiendo el resumen.'}
          </p>
        )}
        {esPreventista && (
          <p className="text-sm text-gray-600 dark:text-gray-400">
            Sólo ve lo suyo: lo que vendió y su cartera. Se arma sin IA, así que no
            tiene costo.
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
              Si lo marcás, deja de llegar el mensaje de cada día. El bot se sigue
              pudiendo usar normalmente.
            </span>
          </span>
        </label>

        {esPreventista && (
          <h3 className="text-base font-semibold text-gray-800 dark:text-white -mb-3">
            Resumen diario
          </h3>
        )}
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
            <ChipsDias elegidos={dias} onToggle={toggleDia} />
          </div>

          {/* Secciones */}
          <div>
            <span className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-2">
              Qué incluye
            </span>
            <div className="grid sm:grid-cols-2 gap-2">
              {opciones.map((s) => (
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

        {esPreventista && (
          <section
            aria-labelledby="aviso-atrasados-h"
            className="space-y-4 rounded-lg border dark:border-gray-700 p-4"
          >
            <div>
              <h3
                id="aviso-atrasados-h"
                className="text-base font-semibold text-gray-800 dark:text-white"
              >
                Aviso semanal de clientes atrasados
              </h3>
              <p className="text-sm text-gray-500 dark:text-gray-400">
                Le llega la lista de sus clientes que dejaron de comprar a su ritmo, con un
                botón por cliente para ver qué ofrecerle. No usa IA.
              </p>
            </div>
            <label className="flex items-center gap-3 cursor-pointer">
              <input
                type="checkbox"
                checked={avisoActivo}
                onChange={(e) => setAvisoActivo(e.target.checked)}
                className="w-4 h-4 rounded border-gray-300 text-blue-600 focus:ring-blue-500"
              />
              <span className="font-medium text-gray-800 dark:text-white">Recibir el aviso</span>
            </label>
            <fieldset disabled={!avisoActivo} className={avisoActivo ? '' : 'opacity-50'}>
              <div className="mb-4">
                <label
                  htmlFor="config-aviso-hora"
                  className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-1"
                >
                  Hora del aviso
                </label>
                <select
                  id="config-aviso-hora"
                  value={avisoHora}
                  onChange={(e) => setAvisoHora(Number(e.target.value))}
                  className="w-40 px-3 py-2 border dark:border-gray-600 rounded-md bg-white dark:bg-gray-700 text-gray-800 dark:text-white"
                >
                  {HORAS.map((h) => (
                    <option key={h} value={h}>
                      {formatHora(h)}
                    </option>
                  ))}
                </select>
              </div>
              <div>
                <span className="block text-sm font-medium text-gray-700 dark:text-gray-200 mb-2">
                  Días del aviso
                </span>
                <ChipsDias elegidos={avisoDias} onToggle={toggleAvisoDia} sufijoLabel=" (aviso)" />
              </div>
            </fieldset>
          </section>
        )}

        {(problema || problemaAviso || error) && (
          <p
            role="alert"
            className="flex items-start gap-2 text-sm text-red-600 dark:text-red-400"
          >
            <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" aria-hidden="true" />
            {problema ?? problemaAviso ?? error}
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
            disabled={guardando || problema !== null || problemaAviso !== null}
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

/**
 * Los siete días como chips que se prenden y apagan. Uno solo para el resumen
 * diario y el aviso semanal: el trinquete de botones crudos (#707) cuenta cada
 * <button> con color propio, y un chip de toggle no es un Button.
 */
function ChipsDias({
  elegidos,
  onToggle,
  sufijoLabel = '',
}: {
  elegidos: number[];
  onToggle: (iso: number) => void;
  /** Distingue los chips del aviso de los del resumen para lectores de pantalla. */
  sufijoLabel?: string;
}): ReactElement {
  return (
    <div className="flex flex-wrap gap-2">
      {DIAS_SEMANA.map((d) => {
        const elegido = elegidos.includes(d.iso);
        return (
          <button
            key={d.iso}
            type="button"
            onClick={() => onToggle(d.iso)}
            aria-pressed={elegido}
            aria-label={`${d.largo}${sufijoLabel}`}
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
  );
}
