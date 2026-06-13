/**
 * SheetParada — bottom sheet de la pantalla Ruta Activa (estilo Uber/Rappi).
 *
 * Tres posiciones (vaul snap points):
 *  - Colapsado: píldora con la próxima entrega y distancia.
 *  - Medio (default): tarjeta de la parada activa con acciones grandes
 *    (Navegar / Waze / Entregar). Si el GPS detecta llegada (<100m), la
 *    tarjeta entra en modo "Llegaste" y Entregar pasa a CTA primario.
 *  - Expandido: productos de la parada activa (con salvedad por item) +
 *    lista completa de paradas (tap selecciona) + links de ruta completa.
 *
 * No-modal: el mapa de fondo sigue interactivo.
 */
import { useState, useEffect } from 'react';
import { Drawer } from 'vaul';
import {
  Navigation, Check, MapPin, Phone, AlertTriangle, Gift, ChevronRight, Map as MapIcon,
} from 'lucide-react';
import { formatPrecio, getFormaPagoLabel } from '../../utils/formatters';
import { formatDistancia } from '../../utils/geo';
import { googleMapsNavUrl, googleMapsSearchUrl, wazeNavUrl } from '../../utils/navegacion';
import type { PedidoItemDB, ProductoDB } from '../../types';
import type { PedidoConCliente } from './useEntregaParada';

const SNAP_COLAPSADO = '120px';
const SNAP_MEDIO = 0.52;
const SNAP_EXPANDIDO = 0.94;

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
}

function navUrl(p: PedidoConCliente): string {
  return p.cliente?.latitud != null && p.cliente?.longitud != null
    ? googleMapsNavUrl(Number(p.cliente.latitud), Number(p.cliente.longitud))
    : googleMapsSearchUrl(p.cliente?.direccion || '');
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
}: SheetParadaProps) {
  const [snap, setSnap] = useState<number | string | null>(SNAP_MEDIO);
  const expandido = snap === SNAP_EXPANDIDO;

  const pendientes = paradas.filter(p => p.estado === 'asignado');

  // Al detectar llegada, subir el sheet a la posición media si está colapsado
  // para que el botón Entregar quede a la vista (flujo guiado).
  useEffect(() => {
    if (llegaste) setSnap(s => (s === SNAP_COLAPSADO ? SNAP_MEDIO : s));
  }, [llegaste]);

  return (
    <Drawer.Root
      open
      modal={false}
      dismissible={false}
      snapPoints={[SNAP_COLAPSADO, SNAP_MEDIO, SNAP_EXPANDIDO]}
      activeSnapPoint={snap}
      setActiveSnapPoint={setSnap}
    >
      <Drawer.Portal>
        <Drawer.Content
          aria-describedby={undefined}
          className="fixed bottom-0 left-0 right-0 z-40 flex h-full max-h-[94%] flex-col rounded-t-2xl border-t border-gray-200 bg-white shadow-[0_-8px_30px_rgba(0,0,0,0.18)] outline-none dark:border-gray-700 dark:bg-gray-800"
        >
          <Drawer.Title className="sr-only">Parada actual de la ruta</Drawer.Title>

          {/* Handle de arrastre */}
          <div className="mx-auto mt-2 h-1.5 w-12 flex-shrink-0 rounded-full bg-gray-300 dark:bg-gray-600" />

          <div className={`flex-1 px-4 pb-[max(env(safe-area-inset-bottom),12px)] ${expandido ? 'overflow-y-auto' : 'overflow-hidden'}`}>
            {paradaActiva ? (
              <>
                {/* Encabezado (visible incluso colapsado) */}
                <div className="flex items-center justify-between gap-2 pt-2">
                  <div className="flex items-center gap-2.5 min-w-0">
                    <div className={`flex h-9 w-9 flex-shrink-0 items-center justify-center rounded-full text-sm font-bold text-white ${llegaste ? 'bg-green-600' : 'bg-blue-600'}`}>
                      {paradaActiva.orden_entrega || '•'}
                    </div>
                    <div className="min-w-0">
                      <p className="truncate font-semibold text-gray-900 dark:text-white">
                        {paradaActiva.cliente?.nombre_fantasia || 'Cliente'}
                      </p>
                      <p className="truncate text-xs text-gray-500 dark:text-gray-400">
                        {llegaste
                          ? '📍 Llegaste — confirmá la entrega'
                          : distanciaMetros != null
                            ? `A ${formatDistancia(distanciaMetros)} · ${pendientes.length} pendientes`
                            : `${pendientes.length} entregas pendientes`}
                      </p>
                    </div>
                  </div>
                  <span className="flex-shrink-0 text-lg font-bold text-gray-900 dark:text-white">
                    {formatPrecio(paradaActiva.total)}
                  </span>
                </div>

                {/* Tarjeta de la parada activa (visible desde snap medio) */}
                <div className="mt-3 space-y-3">
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
                    <span className="text-gray-500 dark:text-gray-400">
                      {paradaActiva.items?.length || 0} items
                    </span>
                    {paradaActiva.cliente?.telefono && (
                      <a href={`tel:${paradaActiva.cliente.telefono}`} className="inline-flex items-center gap-1 text-blue-600 dark:text-blue-400">
                        <Phone className="h-3.5 w-3.5" />
                        {paradaActiva.cliente.telefono}
                      </a>
                    )}
                  </div>

                  {paradaActiva.notas && (
                    <p className="rounded-lg border border-yellow-200 bg-yellow-50 p-2 text-xs text-yellow-800 dark:border-yellow-800 dark:bg-yellow-900/20 dark:text-yellow-300">
                      <strong>Nota:</strong> {paradaActiva.notas}
                    </p>
                  )}

                  {/* Acciones principales */}
                  <div className="grid grid-cols-3 gap-2">
                    <a
                      href={navUrl(paradaActiva)}
                      target="_blank"
                      rel="noopener noreferrer"
                      className={`flex min-h-[52px] items-center justify-center gap-1.5 rounded-xl text-sm font-semibold transition-colors ${
                        llegaste
                          ? 'bg-blue-50 text-blue-700 dark:bg-blue-900/30 dark:text-blue-300'
                          : 'bg-blue-600 text-white active:bg-blue-800'
                      }`}
                    >
                      <Navigation className="h-4 w-4" />
                      Navegar
                    </a>
                    {paradaActiva.cliente?.latitud != null && paradaActiva.cliente?.longitud != null ? (
                      <a
                        href={wazeNavUrl(Number(paradaActiva.cliente.latitud), Number(paradaActiva.cliente.longitud))}
                        target="_blank"
                        rel="noopener noreferrer"
                        className="flex min-h-[52px] items-center justify-center gap-1.5 rounded-xl bg-cyan-50 text-sm font-semibold text-cyan-700 transition-colors active:bg-cyan-100 dark:bg-cyan-900/30 dark:text-cyan-300"
                      >
                        <Navigation className="h-4 w-4" />
                        Waze
                      </a>
                    ) : <span />}
                    <button
                      onClick={() => onEntregar(paradaActiva)}
                      className={`flex min-h-[52px] items-center justify-center gap-1.5 rounded-xl text-sm font-semibold transition-colors ${
                        llegaste
                          ? 'bg-green-600 text-white active:bg-green-800'
                          : 'bg-green-50 text-green-700 active:bg-green-100 dark:bg-green-900/30 dark:text-green-300'
                      }`}
                    >
                      <Check className="h-5 w-5" />
                      Entregar
                    </button>
                  </div>
                </div>
              </>
            ) : (
              <div className="flex items-center justify-between pt-2">
                <p className="font-semibold text-gray-900 dark:text-white">🎉 Ruta completada</p>
                <p className="text-sm text-gray-500 dark:text-gray-400">No quedan entregas pendientes</p>
              </div>
            )}

            {/* Contenido expandido: productos de la parada + lista de paradas */}
            {expandido && (
              <div className="mt-5 space-y-5">
                {paradaActiva && (paradaActiva.items?.length || 0) > 0 && (
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
                              : 'bg-gray-50 dark:bg-gray-700'
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
                              onClick={() => onSalvedad(paradaActiva.id, item)}
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

                <div>
                  <p className="mb-2 text-xs font-semibold uppercase tracking-wide text-gray-500 dark:text-gray-400">
                    Todas las paradas
                  </p>
                  <div className="space-y-1.5">
                    {paradas.map((p, i) => {
                      const entregado = p.estado === 'entregado';
                      const activa = paradaActiva?.id === p.id;
                      return (
                        <button
                          key={p.id}
                          onClick={() => { onSeleccionarParada(p.id); setSnap(SNAP_MEDIO); }}
                          className={`flex w-full items-center gap-3 rounded-xl border p-2.5 text-left transition-colors ${
                            activa
                              ? 'border-blue-400 bg-blue-50 dark:border-blue-600 dark:bg-blue-900/30'
                              : 'border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-800'
                          }`}
                        >
                          <span className={`flex h-8 w-8 flex-shrink-0 items-center justify-center rounded-full text-xs font-bold text-white ${entregado ? 'bg-green-500' : 'bg-blue-500'}`}>
                            {entregado ? <Check className="h-4 w-4" /> : (p.orden_entrega || i + 1)}
                          </span>
                          <span className="min-w-0 flex-1">
                            <span className="block truncate text-sm font-medium text-gray-900 dark:text-white">
                              {p.cliente?.nombre_fantasia || 'Cliente'}
                            </span>
                            <span className="block truncate text-xs text-gray-500 dark:text-gray-400">
                              {p.cliente?.direccion || 'Sin dirección'}
                            </span>
                          </span>
                          <span className="flex-shrink-0 text-sm font-semibold text-gray-700 dark:text-gray-300">
                            {formatPrecio(p.total)}
                          </span>
                          <ChevronRight className="h-4 w-4 flex-shrink-0 text-gray-400" />
                        </button>
                      );
                    })}
                  </div>
                </div>

                {linksRutaMaps.length > 0 && (
                  <div>
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
                          className="inline-flex min-h-[44px] items-center gap-2 rounded-lg bg-gray-100 px-4 py-2 text-sm font-medium text-gray-700 dark:bg-gray-700 dark:text-gray-200"
                        >
                          <MapIcon className="h-4 w-4" />
                          {linksRutaMaps.length === 1 ? 'Abrir ruta completa' : `Tramo ${i + 1} (${link.desde}-${link.hasta})`}
                        </a>
                      ))}
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>
        </Drawer.Content>
      </Drawer.Portal>
    </Drawer.Root>
  );
}
