/**
 * Configuración comercial de la sucursal activa.
 *
 * Pantalla de configuración del sistema: la compra mínima por pedido (mig 204)
 * y los dos % de comisión por defecto (mig 207). Es el lugar donde van las
 * políticas que vengan: sumar una es una columna en `politicas_comerciales` y
 * un campo acá.
 */
import { useState, useEffect, type FormEvent, type ReactNode } from 'react';
import { Loader2, Settings, AlertTriangle, Percent, CalendarClock, PackageX, History, Boxes } from 'lucide-react';
import { Button } from '../ui/Button';
import { formatCurrency } from '../../utils/formatters';
import type { ModoMinimoPedido, ReglaMinimoPedido } from '../../utils/montoMinimo';

export interface VistaConfiguracionProps {
  montoMinimoActual: number;
  /** Qué pasa bajo el mínimo: se rechaza, se cobra envío o ambas según el tramo (mig 389). */
  modoMinimoActual?: ModoMinimoPedido;
  /** Solo en escalas: desde este total no se cobra envío. */
  montoEnvioGratisActual?: number;
  /** Cargo de envío en $ de los modos cargo y escalas. */
  cargoEnvioActual?: number;
  cargando: boolean;
  guardando: boolean;
  /** Impacto del valor tipeado sobre los últimos 90 días. */
  impacto?: { total: number; bloqueados: number };
  impactoCargando: boolean;
  /** Lo dispara el container al tipear, para recalcular el impacto. */
  onMontoTipeado: (monto: number) => void;
  onGuardar: (regla: ReglaMinimoPedido) => void;
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
  /** Si al tomar un pedido se listan los productos sin stock (deshabilitados). */
  mostrarSinStock: boolean;
  guardandoMostrarSinStock: boolean;
  onGuardarMostrarSinStock: (mostrar: boolean) => void;
  /** Horas de tolerancia al precio anterior tras un cambio de lista (#1157). */
  ventanaPrecioAnteriorHoras: number;
  /** Solo el admin la cambia (la RPC rechaza al resto); el encargado la ve. */
  puedeEditarVentana: boolean;
  guardandoVentana: boolean;
  onGuardarVentana: (horas: number) => void;
  /** Topes de las alertas de combos (#1194). Sin `onGuardarAlertasCombos` no se muestra. */
  comboMargenMinimoPct?: number;
  comboDescuentoMaximoPct?: number;
  /** Solo el admin los cambia (la RPC rechaza al resto). */
  puedeEditarAlertasCombos?: boolean;
  guardandoAlertasCombos?: boolean;
  onGuardarAlertasCombos?: (margenMinimoPct: number, descuentoMaximoPct: number) => void;
  /** Secciones que no son de la sucursal activa (ej. impuestos internos, mig 277). */
  extra?: ReactNode;
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
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
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
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
            <span className="text-stone-500 dark:text-stone-400">dias antes</span>
          </div>
        </div>
      </div>

      {error && (
        <p role="alert" className="text-rose-600 text-xs">{error}</p>
      )}

      <div className="flex items-center gap-3">
        <Button
          type="submit"
          variant="primary"
          size="md"
          disabled={guardando || !cambio}
          loading={guardando}
        >
          Guardar avisos
        </Button>
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
 * Si los productos sin stock se listan al tomar pedidos.
 *
 * Es una sola decisión de sí/no, pero va con su botón Guardar como el resto de
 * la pantalla: un tilde que guarda solo, en un celular, se activa sin querer.
 */
function FormMostrarSinStock({
  mostrar,
  guardando,
  onGuardar,
}: {
  mostrar: boolean;
  guardando: boolean;
  onGuardar: (mostrar: boolean) => void;
}) {
  const [valor, setValor] = useState(mostrar);

  // El valor del servidor llega despues del primer render y cambia al cambiar
  // de sucursal.
  useEffect(() => { setValor(mostrar); }, [mostrar]);

  const cambio = valor !== mostrar;

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    onGuardar(valor);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
    >
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <PackageX className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Productos sin stock
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          Apagado, los productos sin stock no se ofrecen al tomar un pedido, ni en la app
          ni en el bot. Prendido se ven, pero no se pueden agregar.
        </p>
      </div>

      <label htmlFor="mostrar-sin-stock" className="flex items-center gap-3 text-sm font-medium text-stone-900 dark:text-white cursor-pointer">
        <input
          id="mostrar-sin-stock"
          type="checkbox"
          checked={valor}
          onChange={(e) => setValor(e.target.checked)}
          className="w-4 h-4 rounded border-stone-300 dark:border-gray-600 text-blue-600 focus:ring-2 focus:ring-blue-500"
        />
        Mostrar productos sin stock al tomar pedidos
      </label>

      <div className="flex items-center gap-3">
        <Button
          type="submit"
          variant="primary"
          size="md"
          disabled={guardando || !cambio}
          loading={guardando}
        >
          Guardar
        </Button>
        {!cambio && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigente: {mostrar ? 'se muestran' : 'no se muestran'}
          </span>
        )}
      </div>
    </form>
  );
}

/**
 * La ventana de precio anterior (#1157): cuántas horas después de un cambio de
 * lista quien no es admin todavía puede vender al precio anterior.
 *
 * Solo la cambia el admin: afloja el piso y el techo de precio, que rigen para
 * el encargado, y si él la pudiera cambiar ampliaría su propia tolerancia. El
 * encargado la ve en solo lectura. El aviso dice que no es solo para el pedido
 * sin señal: quien está online también la puede usar, en las dos direcciones.
 */
function FormVentanaPrecioAnterior({
  horas,
  puedeEditar,
  guardando,
  onGuardar,
}: {
  horas: number;
  puedeEditar: boolean;
  guardando: boolean;
  onGuardar: (horas: number) => void;
}) {
  const [valor, setValor] = useState(String(horas));

  // El valor del servidor llega después del primer render y cambia al cambiar
  // de sucursal.
  useEffect(() => { setValor(String(horas)); }, [horas]);

  const n = Number(valor);
  // Mismo rango que el CHECK de la tabla y la RPC: entero de 0 a 168.
  const invalido = valor.trim() === '' || !Number.isInteger(n) || n < 0 || n > 168;
  const cambio = !invalido && n !== horas;

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (invalido || !puedeEditar) return;
    onGuardar(n);
  }

  return (
    <form
      onSubmit={handleSubmit}
      className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
    >
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <History className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Ventana de precio anterior
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          Después de un cambio de lista, durante estas horas quien no es admin todavía puede
          vender al precio anterior. Sirve para que un pedido cargado sin señal antes del cambio
          no se rechace al sincronizar. Pero vale también para quien tiene señal: tras una suba
          puede cobrar el precio viejo, más barato, y tras una baja, el viejo, más caro. Con 0 no
          hay tolerancia: el pedido sin señal compuesto antes del cambio se rechaza. Máximo 168
          (una semana).
        </p>
        {!puedeEditar && (
          <p className="text-xs text-stone-500 dark:text-stone-400 mt-2">
            Solo un admin puede cambiarla.
          </p>
        )}
      </div>

      <div>
        <label htmlFor="ventana-precio-anterior" className="block text-sm font-medium text-stone-900 dark:text-white">
          Horas
        </label>
        <div className="mt-2 flex items-center gap-2">
          <input
            id="ventana-precio-anterior"
            type="number"
            min={0}
            max={168}
            step={1}
            inputMode="numeric"
            value={valor}
            onChange={(e) => setValor(e.target.value)}
            disabled={!puedeEditar}
            aria-invalid={invalido}
            aria-describedby={invalido ? 'ventana-precio-anterior-error' : undefined}
            className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
          />
          <span className="text-stone-500 dark:text-stone-400">horas</span>
        </div>
        {invalido && (
          <p id="ventana-precio-anterior-error" role="alert" className="text-xs text-red-600 mt-2">
            Ingresá una cantidad entera de horas entre 0 y 168.
          </p>
        )}
      </div>

      <div className="flex items-center gap-3">
        <Button
          type="submit"
          variant="primary"
          size="md"
          disabled={guardando || !cambio || invalido || !puedeEditar}
          loading={guardando}
        >
          Guardar
        </Button>
        {!cambio && !invalido && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigente: {horas} h
          </span>
        )}
      </div>
    </form>
  );
}

/**
 * Los topes de las alertas de combos (#1194). El combo tiene precio fijo y con
 * inflación queda viejo: el panel de combos y el reporte gerencial avisan
 * cuando el margen baja del mínimo o el descuento pasa del máximo. Avisan, no
 * bloquean. Solo los cambia el admin, como la ventana de precio anterior.
 */
function FormAlertasCombos({
  margenMinimo,
  descuentoMaximo,
  puedeEditar,
  guardando,
  onGuardar,
}: {
  margenMinimo: number;
  descuentoMaximo: number;
  puedeEditar: boolean;
  guardando: boolean;
  onGuardar: (margenMinimoPct: number, descuentoMaximoPct: number) => void;
}) {
  const [margen, setMargen] = useState(String(margenMinimo));
  const [descuento, setDescuento] = useState(String(descuentoMaximo));

  useEffect(() => { setMargen(String(margenMinimo)); }, [margenMinimo]);
  useEffect(() => { setDescuento(String(descuentoMaximo)); }, [descuentoMaximo]);

  const nM = Number(margen.replace(',', '.'));
  const nD = Number(descuento.replace(',', '.'));
  // Mismo rango que el CHECK de la tabla y la RPC: 0 a 100.
  const fueraDeRango = (txt: string, n: number) => txt.trim() === '' || !Number.isFinite(n) || n < 0 || n > 100;
  const invalido = fueraDeRango(margen, nM) || fueraDeRango(descuento, nD);
  const cambio = !invalido && (nM !== margenMinimo || nD !== descuentoMaximo);

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (invalido || !puedeEditar) return;
    onGuardar(nM, nD);
  }

  const inputCls = 'w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500';

  return (
    <form
      onSubmit={handleSubmit}
      className="bg-white dark:bg-gray-800 border border-stone-200/80 dark:border-gray-700 rounded-xl p-5 space-y-4 shadow-warm"
    >
      <div>
        <h2 className="text-sm font-semibold text-stone-900 dark:text-white flex items-center gap-2">
          <Boxes className="w-4 h-4 text-stone-500" aria-hidden="true" />
          Alertas de combos
        </h2>
        <p className="text-xs text-stone-500 dark:text-stone-400 mt-1">
          El precio de un combo es fijo: si suben los costos el margen se achica, y si suben las
          listas el descuento crece. El panel de combos y el reporte gerencial avisan cuando el
          margen del combo (sobre la venta sin IVA) baja de este mínimo o el descuento contra
          comprar por separado pasa de este máximo. Solo avisan: el combo se sigue vendiendo.
        </p>
        {!puedeEditar && (
          <p className="text-xs text-stone-500 dark:text-stone-400 mt-2">
            Solo un admin puede cambiarlas.
          </p>
        )}
      </div>

      <div className="flex flex-wrap gap-6">
        <div>
          <label htmlFor="combo-margen-minimo" className="block text-sm font-medium text-stone-900 dark:text-white">
            Margen mínimo
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="combo-margen-minimo"
              type="text"
              inputMode="decimal"
              value={margen}
              onChange={(e) => setMargen(e.target.value)}
              disabled={!puedeEditar}
              aria-invalid={fueraDeRango(margen, nM)}
              className={inputCls}
            />
            <span className="text-stone-500 dark:text-stone-400">%</span>
          </div>
        </div>
        <div>
          <label htmlFor="combo-descuento-maximo" className="block text-sm font-medium text-stone-900 dark:text-white">
            Descuento máximo
          </label>
          <div className="mt-2 flex items-center gap-2">
            <input
              id="combo-descuento-maximo"
              type="text"
              inputMode="decimal"
              value={descuento}
              onChange={(e) => setDescuento(e.target.value)}
              disabled={!puedeEditar}
              aria-invalid={fueraDeRango(descuento, nD)}
              className={inputCls}
            />
            <span className="text-stone-500 dark:text-stone-400">%</span>
          </div>
        </div>
      </div>
      {invalido && (
        <p role="alert" className="text-xs text-red-600">
          Los dos topes van de 0 a 100%.
        </p>
      )}

      <div className="flex items-center gap-3">
        <Button
          type="submit"
          variant="primary"
          size="md"
          disabled={guardando || !cambio || invalido || !puedeEditar}
          loading={guardando}
        >
          Guardar
        </Button>
        {!cambio && !invalido && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigentes: margen mínimo {margenMinimo}%, descuento máximo {descuentoMaximo}%
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
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
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
              className="w-28 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
            <span className="text-stone-500 dark:text-stone-400">%</span>
          </div>
        </div>
      </div>

      {error && (
        <p role="alert" className="text-rose-600 text-xs">{error}</p>
      )}

      <div className="flex items-center gap-3">
        <Button
          type="submit"
          variant="primary"
          size="md"
          disabled={guardando || !cambio}
          loading={guardando}
        >
          Guardar comisiones
        </Button>
        {!cambio && valido && (
          <span className="text-xs text-stone-500 dark:text-stone-400">
            Vigente: {pctPreventista}% preventistas · {pctOtros}% el resto
          </span>
        )}
      </div>
    </form>
  );
}

const MODOS_MINIMO: Array<{ value: ModoMinimoPedido; titulo: string; detalle: string }> = [
  {
    value: 'bloquear',
    titulo: 'Bloquear',
    detalle: 'Bajo el mínimo el pedido no se puede cargar.',
  },
  {
    value: 'cargo',
    titulo: 'Cobrar envío',
    detalle: 'Bajo el mínimo el pedido se carga y paga un cargo de envío.',
  },
  {
    value: 'escalas',
    titulo: 'Por escalas',
    detalle: 'Bajo el mínimo se bloquea; hasta el monto de envío gratis se cobra el envío; desde ahí, nada.',
  },
];

function parsearMonto(v: string): number {
  return Number(v.replace(',', '.'));
}

export default function VistaConfiguracion({
  montoMinimoActual,
  modoMinimoActual = 'bloquear',
  montoEnvioGratisActual = 0,
  cargoEnvioActual = 0,
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
  mostrarSinStock,
  guardandoMostrarSinStock,
  onGuardarMostrarSinStock,
  onGuardarAlertas,
  ventanaPrecioAnteriorHoras,
  puedeEditarVentana,
  guardandoVentana,
  onGuardarVentana,
  comboMargenMinimoPct = 10,
  comboDescuentoMaximoPct = 30,
  puedeEditarAlertasCombos = false,
  guardandoAlertasCombos = false,
  onGuardarAlertasCombos,
  extra,
}: VistaConfiguracionProps) {
  const [valor, setValor] = useState(String(montoMinimoActual ?? 0));
  const [modo, setModo] = useState<ModoMinimoPedido>(modoMinimoActual);
  const [gratis, setGratis] = useState(String(montoEnvioGratisActual ?? 0));
  const [cargo, setCargo] = useState(String(cargoEnvioActual ?? 0));
  const [error, setError] = useState<string | null>(null);

  // El valor del servidor llega después del primer render (y cambia al cambiar
  // de sucursal): sin esto el campo se quedaría mostrando 0.
  useEffect(() => {
    setValor(String(montoMinimoActual ?? 0));
  }, [montoMinimoActual]);
  useEffect(() => { setModo(modoMinimoActual); }, [modoMinimoActual]);
  useEffect(() => { setGratis(String(montoEnvioGratisActual ?? 0)); }, [montoEnvioGratisActual]);
  useEffect(() => { setCargo(String(cargoEnvioActual ?? 0)); }, [cargoEnvioActual]);

  const parseado = parsearMonto(valor);
  const parseadoGratis = parsearMonto(gratis);
  const parseadoCargo = parsearMonto(cargo);
  const cobraEnvio = modo !== 'bloquear';
  const esEscalas = modo === 'escalas';
  const valido = Number.isFinite(parseado) && parseado >= 0;
  const montosValidos = valido
    && (!cobraEnvio || (Number.isFinite(parseadoCargo) && parseadoCargo >= 0))
    && (!esEscalas || (Number.isFinite(parseadoGratis) && parseadoGratis > parseado));
  const cambio = montosValidos && (
    parseado !== montoMinimoActual
    || modo !== modoMinimoActual
    || (cobraEnvio && parseadoCargo !== cargoEnvioActual)
    || (esEscalas && parseadoGratis !== montoEnvioGratisActual)
  );

  function handleChange(v: string) {
    setValor(v);
    setError(null);
    const n = parsearMonto(v);
    if (Number.isFinite(n) && n >= 0) onMontoTipeado(n);
  }

  function handleSubmit(e: FormEvent) {
    e.preventDefault();
    if (!valido) {
      setError('Ingresá un monto válido (0 o mayor).');
      return;
    }
    if (cobraEnvio && !(Number.isFinite(parseadoCargo) && parseadoCargo >= 0)) {
      setError('Ingresá un cargo de envío válido (0 o mayor).');
      return;
    }
    if (esEscalas && !(Number.isFinite(parseadoGratis) && parseadoGratis > parseado)) {
      setError('El monto desde el cual el envío es gratis tiene que superar al mínimo.');
      return;
    }
    onGuardar({
      modo,
      montoMinimo: parseado,
      // Los campos que el modo no usa se guardan en 0: no quedan valores viejos
      // escondidos que reaparezcan al cambiar de modo.
      montoEnvioGratis: esEscalas ? parseadoGratis : 0,
      cargoEnvio: cobraEnvio ? parseadoCargo : 0,
    });
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
          <h1 className="text-2xl font-bold text-gray-800 dark:text-white">Configuración</h1>
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
            Qué pasa con un pedido que no llega al mínimo — en la app, sin señal y desde el bot.
            Dejá el mínimo en 0 para no exigir nada.
          </p>

          <fieldset className="mt-3">
            <legend className="sr-only">Qué pasa con un pedido bajo el mínimo</legend>
            <div className="grid gap-2 sm:grid-cols-3">
              {MODOS_MINIMO.map(m => (
                <label
                  key={m.value}
                  className={`cursor-pointer rounded-lg border p-3 text-sm ${
                    modo === m.value
                      ? 'border-blue-500 bg-blue-50 dark:bg-blue-900/20 dark:border-blue-500'
                      : 'border-stone-300 dark:border-gray-600'
                  }`}
                >
                  <span className="flex items-center gap-2 font-medium text-stone-900 dark:text-white">
                    <input
                      type="radio"
                      name="modo-minimo"
                      value={m.value}
                      checked={modo === m.value}
                      onChange={() => { setModo(m.value); setError(null); }}
                    />
                    {m.titulo}
                  </span>
                  <span className="block mt-1 text-xs text-stone-500 dark:text-stone-400">{m.detalle}</span>
                </label>
              ))}
            </div>
          </fieldset>

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
              className="w-48 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
            />
          </div>

          {cobraEnvio && (
            <div className="mt-3 flex flex-wrap items-end gap-4">
              <div>
                <label htmlFor="cargo-envio" className="block text-xs font-medium text-stone-700 dark:text-stone-300">
                  Cargo de envío
                </label>
                <div className="mt-1 flex items-center gap-2">
                  <span className="text-stone-500 dark:text-stone-400">$</span>
                  <input
                    id="cargo-envio"
                    type="number"
                    min={0}
                    step="0.01"
                    inputMode="decimal"
                    value={cargo}
                    onChange={(e) => { setCargo(e.target.value); setError(null); }}
                    className="w-40 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                  />
                </div>
              </div>
              {esEscalas && (
                <div>
                  <label htmlFor="monto-envio-gratis" className="block text-xs font-medium text-stone-700 dark:text-stone-300">
                    Envío gratis desde
                  </label>
                  <div className="mt-1 flex items-center gap-2">
                    <span className="text-stone-500 dark:text-stone-400">$</span>
                    <input
                      id="monto-envio-gratis"
                      type="number"
                      min={0}
                      step="0.01"
                      inputMode="decimal"
                      value={gratis}
                      onChange={(e) => { setGratis(e.target.value); setError(null); }}
                      className="w-40 px-3 py-2 rounded-lg border border-stone-300 dark:border-gray-600 dark:bg-gray-900 dark:text-white focus:ring-2 focus:ring-blue-500 focus:border-blue-500"
                    />
                  </div>
                </div>
              )}
            </div>
          )}
          {cobraEnvio && (
            <p className="text-xs text-stone-500 dark:text-stone-400 mt-2">
              El cargo se suma al total del pedido (el cliente lo debe), pero no es mercadería:
              no entra en comisiones, metas ni margen. Se fija al cargar el pedido; las
              ediciones y salvedades lo conservan y no cambia aunque cambies esta política después.
            </p>
          )}

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
                    de los últimos 90 días {modo === 'cargo'
                      ? 'habrían pagado envío'
                      : 'no se habrían podido cargar'}
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
          <Button
            type="submit"
            variant="primary"
            size="md"
            disabled={guardando || !cambio}
            loading={guardando}
          >
            Guardar
          </Button>
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

      <FormMostrarSinStock
        mostrar={mostrarSinStock}
        guardando={guardandoMostrarSinStock}
        onGuardar={onGuardarMostrarSinStock}
      />

      <FormVentanaPrecioAnterior
        horas={ventanaPrecioAnteriorHoras}
        puedeEditar={puedeEditarVentana}
        guardando={guardandoVentana}
        onGuardar={onGuardarVentana}
      />

      {onGuardarAlertasCombos && (
        <FormAlertasCombos
          margenMinimo={comboMargenMinimoPct}
          descuentoMaximo={comboDescuentoMaximoPct}
          puedeEditar={puedeEditarAlertasCombos}
          guardando={guardandoAlertasCombos}
          onGuardar={onGuardarAlertasCombos}
        />
      )}

      {extra}
    </div>
  );
}
