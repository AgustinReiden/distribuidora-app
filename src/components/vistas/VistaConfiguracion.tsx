/**
 * Configuración comercial de la sucursal activa.
 *
 * Pantalla de configuración del sistema: la compra mínima por pedido (mig 204)
 * y los dos % de comisión por defecto (mig 207). Es el lugar donde van las
 * políticas que vengan: sumar una es una columna en `politicas_comerciales` y
 * un campo acá.
 */
import { useState, useEffect, type FormEvent } from 'react';
import { Loader2, Settings, AlertTriangle, Percent, CalendarClock } from 'lucide-react';
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
  /** % por defecto de quien tiene rol preventista (mig 207). */
  comisionPctPreventista: number;
  /** % por defecto de quien NO es preventista: admin, encargado. */
  comisionPctOtros: number;
  guardandoComisiones: boolean;
  onGuardarComisiones: (pctPreventista: number, pctOtros: number) => void;
  /** Dias de anticipacion del aviso amarillo de vencimiento (mig 223). */
  diasAlertaVencimiento: number;
  /** Dias de anticipacion del aviso rojo. Siempre <= el amarillo. */
  diasCriticoVencimiento: number;
  guardandoAlertas: boolean;
  onGuardarAlertas: (diasAlerta: number, diasCritico: number) => void;
}

/**
 * Los dos umbrales del semaforo de vencimientos.
 *
 * Van juntos y en un solo formulario porque la base los valida juntos: el rojo
 * no puede caer despues del amarillo (CHECK de la mig 223). Mandarlos por
 * separado dejaria un estado intermedio que el servidor rechaza.
 *
 * Que los dos den 0 es una configuracion valida, no un formulario vacio:
 * significa "avisame solo lo que ya se vencio".
 */
function FormAlertasVencimiento({
  diasAlerta,
  diasCritico,
  guardando,
  onGuardar,
}: {
  diasAlerta: number;
  diasCritico: number;
  guardando: boolean;
  onGuardar: (diasAlerta: number, diasCritico: number) => void;
}) {
  const [amarillo, setAmarillo] = useState(String(diasAlerta));
  const [rojo, setRojo] = useState(String(diasCritico));
  const [error, setError] = useState<string | null>(null);

  // El valor del servidor llega despues del primer render y cambia al cambiar
  // de sucursal.
  useEffect(() => { setAmarillo(String(diasAlerta)); }, [diasAlerta]);
  useEffect(() => { setRojo(String(diasCritico)); }, [diasCritico]);

  const nAmarillo = Number(amarillo);
  const nRojo = Number(rojo);
  const validoAmarillo = Number.isInteger(nAmarillo) && nAmarillo >= 0 && nAmarillo <= 3650;
  const validoRojo = Number.isInteger(nRojo) && nRojo >= 0 && nRojo <= 3650;
  const ordenOk = validoAmarillo && validoRojo && nRojo <= nAmarillo;
  const valido = validoAmarillo && validoRojo && ordenOk;
  const cambio = valido && (nAmarillo !== diasAlerta || nRojo !== diasCritico);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!validoAmarillo || !validoRojo) {
      setError('Ingresa una cantidad de dias entre 0 y 3650.');
      return;
    }
    if (!ordenOk) {
      setError('El aviso rojo no puede ser antes que el amarillo.');
      return;
    }
    setError(null);
    onGuardar(nAmarillo, nRojo);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
    >
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <CalendarClock className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Aviso de vencimientos
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          Con cuanta anticipacion se marca un lote en <strong>Vencimientos</strong> y en la
          ficha del producto. El amarillo es &ldquo;ojo con esto, empujalo&rdquo;; el rojo es
          &ldquo;hay que liquidarlo ya&rdquo;.
        </p>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-2">
          Los dos en 0 avisan solo lo que ya se vencio. Un lote vencido nunca bloquea la
          venta: se marca, y vos decidis.
        </p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label htmlFor="dias-alerta" className="block text-sm font-medium text-stone-900 dark:text-white">
            Amarillo
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="dias-alerta"
              type="number"
              min={0}
              max={3650}
              step="1"
              inputMode="numeric"
              value={amarillo}
              onChange={(e) => { setAmarillo(e.target.value); setError(null); }}
              aria-invalid={!validoAmarillo}
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
            <span className="text-stone-500 dark:text-stone-400">dias antes</span>
          </div>
        </div>

        <div>
          <label htmlFor="dias-critico" className="block text-sm font-medium text-stone-900 dark:text-white">
            Rojo
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="dias-critico"
              type="number"
              min={0}
              max={3650}
              step="1"
              inputMode="numeric"
              value={rojo}
              onChange={(e) => { setRojo(e.target.value); setError(null); }}
              aria-invalid={!validoRojo || !ordenOk}
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
            <span className="text-stone-500 dark:text-stone-400">dias antes</span>
          </div>
        </div>
      </div>

      {error && (
        <p role="alert" className="text-rose-600 text-xs">{error}</p>
      )}

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={guardando || !cambio}
          className="px-4 py-2 rounded-lg bg-amber-600 text-white font-semibold text-sm hover:bg-amber-700 disabled:bg-stone-300 dark:disabled:bg-gray-600 disabled:cursor-not-allowed flex items-center gap-2"
        >
          {guardando && <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />}
          Guardar avisos
        </button>
        {!cambio && valido && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigente: amarillo a {diasAlerta} dias / rojo a {diasCritico}
          </span>
        )}
      </div>
    </form>
  );
}


/**
 * Los dos % de comisión por defecto.
 *
 * Van en su propio formulario y no junto al monto mínimo porque son otra
 * decisión y otro RPC: guardar uno no tiene por qué guardar el otro.
 */
function FormComisiones({
  pctPreventista,
  pctOtros,
  guardando,
  onGuardar,
}: {
  pctPreventista: number;
  pctOtros: number;
  guardando: boolean;
  onGuardar: (pctPreventista: number, pctOtros: number) => void;
}) {
  const [prev, setPrev] = useState(String(pctPreventista));
  const [otros, setOtros] = useState(String(pctOtros));
  const [error, setError] = useState<string | null>(null);

  // El valor del servidor llega después del primer render y cambia al cambiar
  // de sucursal.
  useEffect(() => { setPrev(String(pctPreventista)); }, [pctPreventista]);
  useEffect(() => { setOtros(String(pctOtros)); }, [pctOtros]);

  const nPrev = Number(prev.replace(',', '.'));
  const nOtros = Number(otros.replace(',', '.'));
  const validoPrev = Number.isFinite(nPrev) && nPrev >= 0 && nPrev <= 100;
  const validoOtros = Number.isFinite(nOtros) && nOtros >= 0 && nOtros <= 100;
  const valido = validoPrev && validoOtros;
  const cambio = valido && (nPrev !== pctPreventista || nOtros !== pctOtros);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!valido) {
      setError('Ingresá porcentajes entre 0 y 100.');
      return;
    }
    setError(null);
    onGuardar(nPrev, nOtros);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
    >
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <Percent className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Comisión por defecto
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          Es el porcentaje que se usa cuando esa persona no tiene una regla propia cargada
          en <strong>Comisiones → Reglas de comisión</strong>. Si tiene una regla, la regla
          manda y estos valores no la tocan.
        </p>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-2">
          Cargar un pedido siendo admin o encargado es parte del trabajo, no una venta:
          por eso el resto arranca en 0. Para que alguien del resto comisione, cargale su
          regla propia.
        </p>
      </div>

      <div className="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div>
          <label htmlFor="pct-preventista" className="block text-sm font-medium text-stone-900 dark:text-white">
            Preventistas
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="pct-preventista"
              type="number"
              min={0}
              max={100}
              step="0.01"
              inputMode="decimal"
              value={prev}
              onChange={(e) => { setPrev(e.target.value); setError(null); }}
              aria-invalid={!validoPrev}
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
            <span className="text-stone-500 dark:text-stone-400">%</span>
          </div>
        </div>

        <div>
          <label htmlFor="pct-otros" className="block text-sm font-medium text-stone-900 dark:text-white">
            Resto (admin, encargado)
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="pct-otros"
              type="number"
              min={0}
              max={100}
              step="0.01"
              inputMode="decimal"
              value={otros}
              onChange={(e) => { setOtros(e.target.value); setError(null); }}
              aria-invalid={!validoOtros}
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-amber-500 focus:border-amber-500"
            />
            <span className="text-stone-500 dark:text-stone-400">%</span>
          </div>
        </div>
      </div>

      {error && (
        <p role="alert" className="text-rose-600 text-xs">{error}</p>
      )}

      <div className="flex items-center gap-3">
        <button
          type="submit"
          disabled={guardando || !cambio}
          className="px-4 py-2 rounded-lg bg-amber-600 text-white font-semibold text-sm hover:bg-amber-700 disabled:bg-stone-300 dark:disabled:bg-gray-600 disabled:cursor-not-allowed flex items-center gap-2"
        >
          {guardando && <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />}
          Guardar comisiones
        </button>
        {!cambio && valido && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigente: {pctPreventista}% preventistas · {pctOtros}% el resto
          </span>
        )}
      </div>
    </form>
  );
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
  comisionPctPreventista,
  comisionPctOtros,
  guardandoComisiones,
  onGuardarComisiones,
  diasAlertaVencimiento,
  diasCriticoVencimiento,
  guardandoAlertas,
  onGuardarAlertas,
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

      <FormComisiones
        pctPreventista={comisionPctPreventista}
        pctOtros={comisionPctOtros}
        guardando={guardandoComisiones}
        onGuardar={onGuardarComisiones}
      />

      <FormAlertasVencimiento
        diasAlerta={diasAlertaVencimiento}
        diasCritico={diasCriticoVencimiento}
        guardando={guardandoAlertas}
        onGuardar={onGuardarAlertas}
      />
    </div>
  );
}
