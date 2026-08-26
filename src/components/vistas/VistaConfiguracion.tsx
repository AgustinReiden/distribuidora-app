/**
 * Configuración comercial de la sucursal activa.
 *
 * Primera pantalla de configuración del sistema. Hoy tiene una sola política —
 * la compra mínima por pedido — pero es el lugar donde van las que vengan:
 * sumar una es una columna en `politicas_comerciales` (mig 204) y un campo acá.
 */
import { useState, useEffect, type FormEvent } from 'react';
import { Loader2, Settings, AlertTriangle } from 'lucide-react';
import { formatCurrency } from '../../utils/formatters';

export interface VistaConfiguracionProps {
  montoMinimoActual: number;
  cargando: boolean;
  guardando: boolean;
  /** Impacto del valor tipeado sobre los últimos 90 días. */
  impacto?: { total: number; bloqueados: number };
  impactoCargando: boolean;
  /** Lo dispara el container al tipear, para recalcular el impacto. */
  onMontoTipeado: (monto: number) => void;
  onGuardar: (monto: number) => void;
  nombreSucursal?: string | null;
}

export default function VistaConfiguracion({
  montoMinimoActual,
  cargando,
  guardando,
  impacto,
  impactoCargando,
  onMontoTipeado,
  onGuardar,
  nombreSucursal,
}: VistaConfiguracionProps) {
  const [valor, setValor] = useState(String(montoMinimoActual ?? 0));
  const [error, setError] = useState<string | null>(null);

  // El valor del servidor llega después del primer render (y cambia al cambiar
  // de sucursal): sin esto el campo se quedaría mostrando 0.
  useEffect(() => {
    setValor(String(montoMinimoActual ?? 0));
  }, [montoMinimoActual]);

  const parseado = Number(valor.replace(',', '.'));
  const valido = Number.isFinite(parseado) && parseado >= 0;
  const cambio = valido && parseado !== montoMinimoActual;

  function handleChange(v: string) {
    setValor(v);
    setError(null);
    const n = Number(v.replace(',', '.'));
    if (Number.isFinite(n) && n >= 0) onMontoTipeado(n);
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!valido) {
      setError('Ingresá un monto válido (0 o mayor).');
      return;
    }
    onGuardar(parseado);
  }

  if (cargando) {
    return (
      <div className="flex justify-center py-12">
        <Loader2 className="w-6 h-6 animate-spin text-stone-400" aria-label="Cargando" />
      </div>
    );
  }

  return (
    <div className="space-y-6 max-w-2xl">
      <header className="flex items-center gap-3">
        <Settings className="w-6 h-6 text-stone-500" aria-hidden="true" />
        <div>
          <h1 className="text-2xl font-semibold text-stone-900 dark:text-white">Configuración</h1>
          <p className="text-sm text-stone-500 dark:text-stone-400">
            Políticas comerciales de {nombreSucursal || 'la sucursal activa'}
          </p>
        </div>
      </header>

      <form
        onSubmit={handleSubmit}
        className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
      >
        <div>
          <label
            htmlFor="monto-minimo"
            className="block text-sm font-semibold text-stone-900 dark:text-white"
          >
            Compra mínima por pedido
          </label>
          <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
            Ningún pedido de esta sucursal va a poder cargarse por debajo de este monto —
            ni desde la app, ni sin señal, ni desde el bot. Dejalo en 0 para no exigir mínimo.
          </p>

          <div className="mt-3 flex items-center gap-2">
            <span className="text-stone-500 dark:text-stone-400">$</span>
            <input
              id="monto-minimo"
              type="number"
              min={0}
              step="0.01"
              inputMode="decimal"
              value={valor}
              onChange={(e) => handleChange(e.target.value)}
              aria-invalid={!valido}
              aria-describedby={error ? 'monto-minimo-error' : undefined}
              className="w-48 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
          </div>

          {error && (
            <p id="monto-minimo-error" role="alert" className="text-rose-600 text-xs mt-2">
              {error}
            </p>
          )}
        </div>

        {/* Impacto: que nadie elija el número a ciegas. Un mínimo mal puesto no
            falla — simplemente frena la operación, y se nota recién en la calle. */}
        {parseado > 0 && (
          <div className="rounded-lg border border-amber-300 bg-amber-50 dark:bg-amber-900/20 dark:border-amber-700 p-3 text-sm">
            <div className="flex items-start gap-2">
              <AlertTriangle className="w-4 h-4 text-amber-600 dark:text-amber-400 mt-0.5 shrink-0" aria-hidden="true" />
              <div className="text-amber-900 dark:text-amber-200">
                {impactoCargando ? (
                  'Calculando el impacto…'
                ) : impacto && impacto.total > 0 ? (
                  <>
                    Con un mínimo de <strong>{formatCurrency(parseado)}</strong>,{' '}
                    <strong>{impacto.bloqueados}</strong> de los {impacto.total} pedidos
                    de los últimos 90 días no se habrían podido cargar
                    {' '}({Math.round((impacto.bloqueados / impacto.total) * 100)}%).
                  </>
                ) : (
                  'No hay pedidos recientes para estimar el impacto.'
                )}
              </div>
            </div>
          </div>
        )}

        <div className="flex items-center gap-3">
          <button
            type="submit"
            disabled={guardando || !cambio}
            className="px-4 py-2 rounded-lg bg-amber-600 text-white font-semibold text-sm hover:bg-amber-700 disabled:bg-stone-300 dark:disabled:bg-gray-600 disabled:cursor-not-allowed flex items-center gap-2"
          >
            {guardando && <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />}
            Guardar
          </button>
          {!cambio && valido && (
            <span className="text-xs text-stone-500 dark:text-stone-400">
              Mínimo vigente: {formatCurrency(montoMinimoActual)}
            </span>
          )}
        </div>
      </form>
    </div>
  );
}
