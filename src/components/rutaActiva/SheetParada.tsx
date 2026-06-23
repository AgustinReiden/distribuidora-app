/**
 * SheetParada — barra inferior + menú a pantalla completa de la Ruta Activa.
 *
 * En vez de un sheet que se arrastra (vaul, incómodo en iOS), es una BARRA FIJA
 * abajo (resumen de la parada activa + acción primaria contextual) que, al
 * tocarla, despliega un PANEL a pantalla completa con el detalle, los productos,
 * todas las paradas y los links. Volver a tocar (o la flecha) lo oculta. Sin
 * arrastre → más mapa para manejar y cero jank de gestos.
 */
import { useState, useEffect } from 'react';
import {
  Navigation, Square, Check, MapPin, Phone, AlertTriangle, Gift, ChevronRight, ChevronUp, ChevronDown, Map as MapIcon, ArrowLeftRight,
} from 'lucide-react';
import { formatPrecio, getFormaPagoLabel } from '../../utils/formatters';
import { formatDistancia } from '../../utils/geo';
import { googleMapsNavUrl, googleMapsSearchUrl } from '../../utils/navegacion';
import type { PedidoItemDB, ProductoDB } from '../../types';
import type { PedidoConCliente } from './useEntregaParada';

export interface LinkRutaMaps {
  url: string;
  desde: number;
  hasta: number;
}

export interface SheetParadaProps {
  paradas: PedidoConCliente[];
  paradaActiva: PedidoConCliente | null;
  /** Distancia GPS a la parada activa, en metros (null sin señal). */
  distanciaMetros: number | null;
  /** true cuando el GPS está a menos del radio de llegada. */
  llegaste: boolean;
  onSeleccionarParada: (pedidoId: string) => void;
  onEntregar: (pedido: PedidoConCliente) => void;
  onSalvedad?: (pedidoId: string, item: PedidoItemDB & { producto?: ProductoDB }) => void;
  linksRutaMaps: LinkRutaMaps[];
  /** Prende/apaga la guía in-app para la parada activa (toggle). */
  onToggleGuia?: (pedido: PedidoConCliente) => void;
  /** ¿La guía está activa ahora? Define el texto del toggle (Navegar/Parar). */
  guiando?: boolean;
}

function navUrl(p: PedidoConCliente): string {
  return p.cliente?.latitud != null && p.cliente?.longitud != null
    ? googleMapsNavUrl(Number(p.cliente.latitud), Number(p.cliente.longitud))
    : googleMapsSearchUrl(p.cliente?.direccion || '');
}

/** ¿La parada es un cambio/devolución (pedido especial canal='cambio')? */
function esCambio(p: PedidoConCliente | null | undefined): boolean {
  return p?.canal === 'cambio';
}

/** Fila compacta de una parada (lista "Todas las paradas"). */
function FilaParada({ parada, numero, activa, onSelect }: {
  parada: PedidoConCliente;
  numero: number;
  activa: boolean;
  onSelect: () => void;
}) {
  const entregado = parada.estado === 'entregado';
  return (
    <button
      onClick={onSelect}
      className={`flex w-full items-center gap-3 rounded-xl border p-2.5 text-left transition-colors ${
        activa
          ? 'border-blue-400 bg-blue-50 dark:border-blue-600 dark:bg-blue-900/30'
          : 'border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800'
      }`}
    >
      <span className={`flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full text-xs font-bold text-white ${entregado ? 'bg-green-500' : 'bg-blue-500'}`}>
        {entregado ? <Check className="h-4 w-4" /> : numero}
      </span>
      <span className="min-w-0 flex-1">
        <span className="block truncate text-sm font-medium text-gray-900 dark:text-white">
          {parada.cliente?.nombre_fantasia || 'Cliente'}
        </span>
        <span className="block truncate text-xs text-gray-500 dark:text-gray-400">
          {parada.cliente?.direccion || 'Sin dirección'}
        </span>
      </span>
      {esCambio(parada) ? (
        <span className="flex flex-shrink-0 items-center gap-1 rounded-full bg-indigo-100 px-2 py-0.5 text-[11px] font-semibold text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300">
          <ArrowLeftRight className="h-3 w-3" /> Cambio
        </span>
      ) : (
        <span className="flex-shrink-0 text-sm font-semibold text-gray-700 dark:text-gray-300">
          {formatPrecio(parada.total)}
        </span>
      )}
      <ChevronRight className="h-4 w-4 flex-shrink-0 text-gray-400" />
    </button>
  );
}

export default function SheetParada({
  paradas,
  paradaActiva,
  distanciaMetros,
  llegaste,
  onSeleccionarParada,
  onEntregar,
  onSalvedad,
  linksRutaMaps,
  onToggleGuia,
  guiando = false,
}: SheetParadaProps) {
  const [abierto, setAbierto] = useState(false);
  const pendientes = paradas.filter(p => p.estado === 'asignado');
  const tieneCoords = paradaActiva?.cliente?.latitud != null && paradaActiva?.cliente?.longitud != null;

  // Al arrancar la guía, cerrar el panel → más mapa para manejar.
  useEffect(() => {
    if (guiando) setAbierto(false);
  }, [guiando]);

  // Acciones que abren un modal (entregar/cobro/salvedad) cierran el panel
  // primero, así el modal queda sobre el mapa sin pelear z-index con el panel.
  const entregar = (p: PedidoConCliente): void => { setAbierto(false); onEntregar(p); };
  const salvedad = (item: PedidoItemDB & { producto?: ProductoDB }): void => {
    if (!paradaActiva || !onSalvedad) return;
    setAbierto(false);
    onSalvedad(paradaActiva.id, item);
  };

  return (
    <>
      {/* PANEL pantalla completa (se desliza desde abajo al tocar la barra) */}
      <div
        className={`fixed inset-0 z-50 flex flex-col bg-white transition-transform duration-300 ease-out dark:bg-gray-900 ${abierto ? 'translate-y-0' : 'pointer-events-none translate-y-full'}`}
        aria-hidden={!abierto}
      >
        <button
          onClick={() => setAbierto(false)}
          className="flex w-full flex-shrink-0 items-center justify-between gap-2 border-b border-gray-200 px-4 pb-3 pt-[max(env(safe-area-inset-top),12px)] text-left dark:border-gray-700"
        >
          <div className="min-w-0">
            <p className="truncate text-lg font-bold text-gray-900 dark:text-white">
              {paradaActiva?.cliente?.nombre_fantasia || 'Paradas de la ruta'}
            </p>
            <p className="text-xs text-gray-500 dark:text-gray-400">{pendientes.length} entregas pendientes</p>
          </div>
          <span className="flex h-10 w-10 flex-shrink-0 items-center justify-center rounded-full bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-300">
            <ChevronDown className="h-5 w-5" />
          </span>
        </button>

        <div className="min-h-0 flex-1 overflow-y-auto overscroll-contain px-4 py-3 pb-[max(env(safe-area-inset-bottom),16px)]">
          {paradaActiva && (
            <div className="space-y-4">
              <div className="space-y-3">
                <div className="flex items-start gap-2 text-sm text-gray-700 dark:text-gray-300">
                  <MapPin className="mt-0.5 h-4 w-4 flex-shrink-0 text-gray-400" />
                  <div className="min-w-0">
                    <p>{paradaActiva.cliente?.direccion || 'Sin dirección'}</p>
                    {paradaActiva.cliente?.aclaracion_direccion && (
                      <p className="italic text-gray-500 dark:text-gray-400">
                        {paradaActiva.cliente.aclaracion_direccion}
                      </p>
                    )}
                  </div>
                </div>

                {esCambio(paradaActiva) ? (
                  <div className="space-y-2">
                    <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                      <span className="inline-flex items-center gap-1 rounded-full bg-indigo-100 px-2 py-0.5 text-xs font-semibold text-indigo-700 dark:bg-indigo-900/40 dark:text-indigo-300">
                        <ArrowLeftRight className="h-3.5 w-3.5" /> CAMBIO/DEVOLUCIÓN
                      </span>
                      {paradaActiva.cliente?.telefono && (
                        <a href={`tel:${paradaActiva.cliente.telefono}`} className="inline-flex items-center gap-1 text-blue-600 dark:text-blue-400">
                          <Phone className="h-3.5 w-3.5" />
                          {paradaActiva.cliente.telefono}
                        </a>
                      )}
                    </div>
                    <div className="space-y-1 rounded-lg border border-indigo-200 bg-indigo-50 p-2.5 text-sm dark:border-indigo-800 dark:bg-indigo-900/20">
                      <p className="text-gray-700 dark:text-gray-200">
                        <strong>Retirar del cliente:</strong>{' '}
                        {(paradaActiva.cambio?.cantidad_devuelta ?? '?')}x {paradaActiva.cambio?.producto_devuelto_nombre || 'producto'}
                      </p>
                      <p className="text-gray-700 dark:text-gray-200">
                        <strong>Entregar al cliente:</strong>{' '}
                        {(paradaActiva.cambio?.cantidad_entregada ?? '?')}x {paradaActiva.cambio?.producto_entregado_nombre || 'producto'}
                      </p>
                      {paradaActiva.cambio?.observaciones && (
                        <p className="italic text-gray-500 dark:text-gray-400">{paradaActiva.cambio.observaciones}</p>
                      )}
                    </div>
                  </div>
                ) : (
                  <div className="flex flex-wrap items-center gap-x-4 gap-y-1 text-sm">
                    <span className={`rounded-full px-2 py-0.5 text-xs font-semibold ${
                      paradaActiva.estado_pago === 'pagado'
                        ? 'bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-300'
                        : paradaActiva.estado_pago === 'parcial'
                          ? 'bg-yellow-100 text-yellow-700 dark:bg-yellow-900/40 dark:text-yellow-300'
                          : 'bg-red-100 text-red-700 dark:bg-red-900/40 dark:text-red-300'
                    }`}>
                      {paradaActiva.estado_pago === 'pagado' ? 'PAGADO' : paradaActiva.estado_pago === 'parcial' ? 'PARCIAL' : 'A COBRAR'}
                    </span>
                    <span className="text-gray-500 dark:text-gray-400">
                      {getFormaPagoLabel(paradaActiva.forma_pago || '')}
                    </span>
                    <span className="font-semibold text-gray-900 dark:text-white">{formatPrecio(paradaActiva.total)}</span>
                    {paradaActiva.cliente?.telefono && (
                      <a href={`tel:${paradaActiva.cliente.telefono}`} className="inline-flex items-center gap-1 text-blue-600 dark:text-blue-400">
                        <Phone className="h-3.5 w-3.5" />
                        {paradaActiva.cliente.telefono}
                      </a>
                    )}
                  </div>
                )}

                {paradaActiva.notas && (
                  <p className="rounded-lg border border-yellow-200 bg-yellow-50 p-2 text-xs text-yellow-800 dark:border-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-300">
                    <strong>Nota:</strong> {paradaActiva.notas}
                  </p>
                )}

                {/* Acciones completas dentro del panel */}
                {onToggleGuia && (guiando || !llegaste) && tieneCoords && (
                  <button
                    onClick={() => onToggleGuia(paradaActiva)}
                    className={`flex min-h-[52px] w-full items-center justify-center gap-2 rounded-xl text-sm font-semibold transition-colors ${
                      guiando
                        ? 'bg-red-600 text-white active:bg-red-800'
                        : 'bg-blue-600 text-white active:bg-blue-800'
                    }`}
                  >
                    {guiando ? <><Square className="h-5 w-5" /> Parar guía</> : <><Navigation className="h-5 w-5" /> Navegar</>}
                  </button>
                )}
                <div className="grid grid-cols-2 gap-2">
                  <a
                    href={navUrl(paradaActiva)}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="flex min-h-[52px] items-center justify-center gap-1.5 rounded-xl bg-blue-50 text-sm font-semibold text-blue-700 transition-colors active:bg-blue-100 dark:bg-blue-900/30 dark:text-blue-300"
                  >
                    <MapIcon className="h-4 w-4" />
                    Maps
                  </a>
                  <button
                    onClick={() => entregar(paradaActiva)}
                    className={`flex min-h-[52px] items-center justify-center gap-1.5 rounded-xl text-sm font-semibold transition-colors ${
                      llegaste
                        ? 'bg-green-600 text-white active:bg-green-800'
                        : 'bg-green-50 text-green-700 active:bg-green-100 dark:bg-green-900/30 dark:text-green-300'
                    }`}
                  >
                    <Check className="h-5 w-5" />
                    {esCambio(paradaActiva) ? 'Completar cambio' : 'Entregar'}
                  </button>
                </div>
              </div>

              {(paradaActiva.items?.length || 0) > 0 && (
                <div>
                  <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Productos de esta entrega
                  </p>
                  <div className="space-y-1.5">
                    {paradaActiva.items.map(item => (
                      <div
                        key={item.id}
                        className={`flex items-center justify-between gap-2 rounded-lg p-2 text-sm ${
                          item.es_bonificacion
                            ? 'border border-green-200 bg-green-50 dark:border-green-800 dark:bg-green-900/30'
                            : 'bg-gray-50 dark:bg-gray-800'
                        }`}
                      >
                        <span className="flex flex-1 items-center gap-1.5 text-gray-700 dark:text-gray-300">
                          {item.es_bonificacion && <Gift className="h-3.5 w-3.5 flex-shrink-0 text-green-600" />}
                          {item.cantidad}x {item.es_bonificacion && item.descripcion_regalo
                            ? item.descripcion_regalo
                            : (item.producto?.nombre || 'Producto')}
                        </span>
                        {!item.es_bonificacion && (
                          <span className="text-gray-500">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</span>
                        )}
                        {paradaActiva.estado === 'asignado' && onSalvedad && (
                          <button
                            onClick={() => salvedad(item)}
                            className="flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-lg bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300"
                            aria-label="Reportar problema con este item"
                          >
                            <AlertTriangle className="h-4 w-4" />
                          </button>
                        )}
                      </div>
                    ))}
                  </div>
                </div>
              )}
            </div>
          )}

          <div className="mt-5">
            <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
              Todas las paradas
            </p>
            <div className="space-y-1.5">
              {paradas.map((p, i) => (
                <FilaParada
                  key={p.id}
                  parada={p}
                  numero={p.orden_entrega || i + 1}
                  activa={paradaActiva?.id === p.id}
                  onSelect={() => { onSeleccionarParada(p.id); setAbierto(false); }}
                />
              ))}
            </div>
          </div>

          {linksRutaMaps.length > 0 && (
            <div className="mt-5">
              <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                Ruta completa en Google Maps
              </p>
              <div className="flex flex-wrap gap-2">
                {linksRutaMaps.map((link, i) => (
                  <a
                    key={link.url}
                    href={link.url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex min-h-[44px] items-center gap-2 rounded-lg bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200"
                  >
                    <MapIcon className="h-4 w-4" />
                    {linksRutaMaps.length === 1 ? 'Abrir ruta completa' : `Tramo ${i + 1} (${link.desde}-${link.hasta})`}
                  </a>
                ))}
              </div>
            </div>
          )}
        </div>
      </div>

      {/* BARRA fija inferior (siempre visible; tocar el resumen abre el panel) */}
      <div className="fixed inset-x-0 bottom-0 z-40 border-t border-gray-200 bg-white shadow-[0_-8px_30px_rgba(0,0,0,0.18)] dark:border-gray-700 dark:bg-gray-800">
        <div className="flex items-center gap-2.5 px-4 pt-2.5 pb-[max(env(safe-area-inset-bottom),10px)]">
          {paradaActiva ? (
            <>
              <button
                onClick={() => setAbierto(o => !o)}
                className="flex min-w-0 flex-1 items-center gap-2.5 text-left"
                aria-label="Abrir el detalle de la parada"
              >
                <span className={`flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full text-sm font-bold text-white ${llegaste ? 'bg-green-600' : 'bg-blue-600'}`}>
                  {paradaActiva.orden_entrega || '•'}
                </span>
                <span className="min-w-0 flex-1">
                  <span className="block truncate font-semibold text-gray-900 dark:text-white">
                    {paradaActiva.cliente?.nombre_fantasia || 'Cliente'}
                  </span>
                  <span className="block truncate text-xs text-gray-500 dark:text-gray-400">
                    {llegaste
                      ? '📍 Llegaste — confirmá la entrega'
                      : distanciaMetros != null
                        ? `A ${formatDistancia(distanciaMetros)} · ${pendientes.length} pendientes`
                        : `${pendientes.length} entregas pendientes`}
                  </span>
                </span>
                <ChevronUp className={`h-5 w-5 flex-shrink-0 text-gray-400 transition-transform ${abierto ? 'rotate-180' : ''}`} />
              </button>

              {/* Acción primaria contextual (compacta → barra fina, más mapa) */}
              {llegaste ? (
                <button
                  onClick={() => entregar(paradaActiva)}
                  className="flex h-12 flex-shrink-0 items-center gap-1.5 rounded-xl bg-green-600 px-4 text-sm font-semibold text-white active:bg-green-800"
                >
                  <Check className="h-5 w-5" /> {esCambio(paradaActiva) ? 'Completar' : 'Entregar'}
                </button>
              ) : guiando && onToggleGuia ? (
                <button
                  onClick={() => onToggleGuia(paradaActiva)}
                  className="flex h-12 flex-shrink-0 items-center gap-1.5 rounded-xl bg-red-600 px-4 text-sm font-semibold text-white active:bg-red-800"
                >
                  <Square className="h-5 w-5" /> Parar
                </button>
              ) : onToggleGuia && tieneCoords ? (
                <button
                  onClick={() => onToggleGuia(paradaActiva)}
                  className="flex h-12 flex-shrink-0 items-center gap-1.5 rounded-xl bg-blue-600 px-4 text-sm font-semibold text-white active:bg-blue-800"
                >
                  <Navigation className="h-5 w-5" /> Navegar
                </button>
              ) : null}
            </>
          ) : (
            <div className="flex min-h-[44px] w-full items-center justify-between">
              <p className="font-semibold text-gray-900 dark:text-white">🎉 Ruta completada</p>
              <p className="text-sm text-gray-500 dark:text-gray-400">Sin entregas pendientes</p>
            </div>
          )}
        </div>
      </div>
    </>
  );
}
