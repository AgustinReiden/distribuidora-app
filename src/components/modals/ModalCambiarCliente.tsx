import { useMemo, useState, memo } from 'react';
import { Search, X, Loader2, ArrowRight, AlertCircle, Gift, RefreshCw } from 'lucide-react';
import ModalBase from './ModalBase';
import { Button } from '../ui/Button';
import { formatPrecio } from '../../utils/formatters';
import { alicuotaIvaVenta } from '../../utils/alicuotaIvaVenta';
import { calcularNetoVenta } from '../../utils/calculations';
import { usePromocionPedido } from '../../hooks/usePromocionPedido';
import { useFotosCombosPedidoQuery } from '../../hooks/queries/useCombosQuery';
import { usePromoMapQuery } from '../../hooks/queries/usePromocionesQuery';
import { fechaReferenciaPromo } from '../../utils/fechaReferenciaPromo';
import { promosConRegalo } from '../../utils/cupoPromo';
import { promosSinRegaloEnElPedido } from '../../utils/promosSinRegalo';
import { aplicarDescuentoClienteItems } from '../../utils/descuentoCliente';
import { aplicarCombosAlPedido, camposCombo, type CamposCombo } from '../../utils/combosPedido';
import type { ItemPedido } from '../../utils/precioMayorista';
import type { PedidoDB, ProductoDB, ClienteDB } from '../../types';
import { esTipoVB, MENSAJE_VB_NO_SE_EDITA } from '../../utils/valeBlanco';
import { partesCobroCambioCliente } from '../../utils/saldoAFavor';

/** Item recalculado que se envía a la RPC cambiar_cliente_pedido. */
export interface CambiarClienteItem extends CamposCombo {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  esBonificacion?: boolean;
  promocionId?: string;
  neto_unitario?: number;
  iva_unitario?: number;
  impuestos_internos_unitario?: number;
  porcentaje_iva?: number;
}

/** Payload con todo lo que necesita el container para invocar la mutación. */
export interface CambiarClientePayload {
  nuevoClienteId: string;
  items: CambiarClienteItem[];
  total: number;
  totalNeto: number;
  totalIva: number;
  motivo?: string;
  /**
   * #1248: a dónde van los pagos del pedido. 'pedido_nuevo' = fue un error de
   * carga (el cobro viaja; lo que sobre queda a favor del cliente nuevo).
   * 'cliente_original' = el cliente no tomó el pedido (lo que pagó le queda a
   * favor). Sin pagos no se manda y el server usa 'pedido_nuevo'.
   */
  destinoPagos?: DestinoPagos;
}

export type DestinoPagos = 'pedido_nuevo' | 'cliente_original';

export interface ModalCambiarClienteProps {
  pedido: PedidoDB;
  productos: ProductoDB[];
  clientes: ClienteDB[];
  onConfirmar: (payload: CambiarClientePayload) => void | Promise<void>;
  onClose: () => void;
  guardando: boolean;
}

/**
 * Cambia el cliente de un pedido cargado al cliente equivocado. Recalcula los
 * precios y los descuentos para el cliente nuevo (no copia los del viejo), pero
 * el regalo y el vendedor son los del pedido (#1513). Muestra una comparación
 * total anterior vs nuevo, y al confirmar delega en el container que cancela el
 * pedido viejo y crea uno nuevo idéntico (RPC atómica).
 */
const ModalCambiarCliente = memo(function ModalCambiarCliente({
  pedido,
  productos,
  clientes,
  onConfirmar,
  onClose,
  guardando,
}: ModalCambiarClienteProps) {
  const [busquedaCliente, setBusquedaCliente] = useState<string>('');
  const [nuevoClienteId, setNuevoClienteId] = useState<string>('');

  const tipoFactura = pedido.tipo_factura ?? 'ZZ';
  // Un vale blanco no cambia de cliente (se cancela y se recarga): el container
  // no abre este modal para un VB y la RPC lo rechaza; esto cierra el camino.
  const esVB = esTipoVB(tipoFactura);

  // Cliente actual (para mostrarlo de referencia).
  const clienteActual = useMemo(
    () => clientes.find(c => String(c.id) === String(pedido.cliente_id)) ?? pedido.cliente ?? null,
    [clientes, pedido.cliente_id, pedido.cliente],
  );

  const clienteNuevo = useMemo(
    () => (nuevoClienteId ? clientes.find(c => String(c.id) === String(nuevoClienteId)) ?? null : null),
    [clientes, nuevoClienteId],
  );

  // Buscador de cliente (réplica del de ModalPedido), excluyendo el cliente actual.
  const clientesFiltrados = useMemo(() => {
    if (busquedaCliente.length < 2) return [];
    const busquedaNorm = busquedaCliente.replace(/\s+/g, ' ').trim().toLowerCase();
    if (!busquedaNorm) return [];
    const norm = (s: string | null | undefined) => s?.replace(/\s+/g, ' ').trim().toLowerCase() ?? '';
    return clientes
      .filter(c => String(c.id) !== String(pedido.cliente_id))
      .filter(c =>
        norm(c.nombre_fantasia).includes(busquedaNorm) ||
        norm(c.razon_social).includes(busquedaNorm) ||
        norm(c.direccion).includes(busquedaNorm) ||
        c.cuit?.includes(busquedaCliente.replace(/[-\s]/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busquedaCliente.trim())),
      )
      .slice(0, 8);
  }, [clientes, busquedaCliente, pedido.cliente_id]);

  // Items de venta del pedido viejo -> base para recalcular. Las bonificaciones
  // van aparte (son las del pedido, ver regalosDelPedido) y se parte del precio
  // de LISTA del producto, no del precio_unitario viejo (que ya traía
  // mayorista/descuento del cliente equivocado embebido).
  // #1191: un producto en combo son dos líneas (la del combo y la suelta): acá
  // va una por producto y los combos se vuelven a armar abajo.
  // VTA-05 (#1513): un producto que hoy no tiene precio de lista conserva el del
  // pedido, como en la edición: recrear la línea no es una venta nueva.
  const itemsVenta = useMemo<ItemPedido[]>(() => {
    const porProducto = new Map<string, ItemPedido>();
    for (const i of pedido.items ?? []) {
      if (i.es_bonificacion) continue;
      const productoId = String(i.producto_id);
      const previo = porProducto.get(productoId);
      if (previo) {
        previo.cantidad += Number(i.cantidad);
        continue;
      }
      const prod = productos.find(p => String(p.id) === productoId);
      const lista = Number(prod?.precio);
      porProducto.set(productoId, lista > 0
        ? { productoId, cantidad: Number(i.cantidad), precioUnitario: lista }
        : {
            productoId,
            cantidad: Number(i.cantidad),
            precioUnitario: Number(i.combo_id ? (i.precio_sin_combo_unitario ?? i.precio_unitario) : i.precio_unitario),
            precioOverride: true,
          });
    }
    return [...porProducto.values()];
  }, [pedido.items, productos]);

  // PRM-1 (#1513): el regalo del pedido nuevo es el del pedido tal cual, línea
  // por línea: el sabor que eligió el admin o el que dejó una sustitución, su
  // cantidad y las partes de un reparto. Si el camión ya salió, salió con eso.
  // El server lo exige y hereda la foto de la promo y las cadenas.
  const regalosDelPedido = useMemo(
    () => (pedido.items ?? [])
      .filter(i => i.es_bonificacion)
      .sort((a, b) => Number(a.id) - Number(b.id)),
    [pedido.items],
  );

  // Mayorista + promos para el cliente nuevo, y los combos (#1191), con la fecha
  // del pedido topada a hoy, como la edición (#1152, #1260). combos_vigentes
  // recibe el pedido para no contar sus propios combos contra el tope, y los
  // combos que ya tiene se miden contra su foto. El regalo de una promo que se
  // apagó sigue: reatribuir no es una venta nueva (#1300).
  // PRM-2 (#1515): una promo de la que el pedido no tiene regalo (alguien la
  // quitó) no vuelve: sus productos siguen tomando el precio mayorista.
  const { data: fotosCombos } = useFotosCombosPedidoQuery(esVB ? undefined : String(pedido.id));
  const promosDelPedido = useMemo(() => promosConRegalo(pedido.items), [pedido.items]);
  const fechaPromo = fechaReferenciaPromo(pedido.fecha);
  const { data: promoMapDelPedido } = usePromoMapQuery(fechaPromo, promosDelPedido);
  const promosQueNoTenia = useMemo(
    () => new Set(promosSinRegaloEnElPedido(itemsVenta, promoMapDelPedido, promosDelPedido).map(p => p.promoId)),
    [itemsVenta, promoMapDelPedido, promosDelPedido],
  );
  const { itemsFinales, isLoading, promoResolucion, pricingMap, combos } = usePromocionPedido(
    itemsVenta, fechaPromo, undefined, promosQueNoTenia, undefined,
    { habilitados: !esVB, pedidoId: String(pedido.id), fotos: fotosCombos, promosDelPedido });

  // Descuento del cliente nuevo (general + categoría) sobre los items resueltos.
  const descuento = useMemo(
    () => aplicarDescuentoClienteItems(itemsFinales, productos, clienteNuevo),
    [itemsFinales, productos, clienteNuevo],
  );

  // #1191: los combos sobre los precios del cliente nuevo, como en el alta.
  const conCombos = useMemo(
    () => aplicarCombosAlPedido({
      itemsBase: itemsVenta,
      lineas: descuento.items,
      productosConPromo: promoResolucion.productosConPromo,
      pricingMap,
      productos,
      cliente: clienteNuevo,
      combos,
    }),
    [itemsVenta, descuento, promoResolucion, pricingMap, productos, clienteNuevo, combos],
  );

  // La reatribución conserva el cargo de envío del pedido (mig 389, #1220):
  // `pedido.total` lo incluye y el total recalculado de las líneas no.
  const cargoEnvio = Number(pedido.cargo_envio) || 0;
  const totalNuevo = conCombos.total + (conCombos.total > 0 ? cargoEnvio : 0);
  const totalViejo = pedido.total ?? 0;
  const delta = totalNuevo - totalViejo;

  // #1489: lo que vino del saldo a favor del cliente actual o de un pago a cuenta
  // de su ficha vuelve a quedarle a favor con cualquier destino. Sólo el cobro de
  // la boleta se pregunta.
  const partesCobro = useMemo(
    () => partesCobroCambioCliente(pedido.monto_pagado, pedido.pagos),
    [pedido.monto_pagado, pedido.pagos],
  );
  const tienePago = partesCobro.cobro > 0.005;
  // #1248: con pagos, la elección es obligatoria y sin default. Depende de por
  // qué se cambia el cliente, y equivocarse le deja la plata a otro.
  const [destinoPagos, setDestinoPagos] = useState<DestinoPagos | null>(null);
  const faltaDestino = tienePago && destinoPagos == null;

  const handleConfirmar = (): void => {
    if (!clienteNuevo || isLoading || guardando || esVB || faltaDestino) return;

    let total = 0;
    let totalNeto = 0;
    let totalIva = 0;

    const items: CambiarClienteItem[] = conCombos.lineas.filter(item => !item.esBonificacion).map(item => {
      const productoId = String(item.productoId);
      const prod = productos.find(p => String(p.id) === productoId);
      const pctIva = alicuotaIvaVenta(prod);
      const pctImpInt = prod?.impuestos_internos ?? 0;
      const desglose = calcularNetoVenta(item.precioUnitario, pctIva, pctImpInt, tipoFactura);
      total += item.precioUnitario * item.cantidad;
      totalNeto += desglose.neto * item.cantidad;
      totalIva += desglose.iva * item.cantidad;
      return {
        productoId,
        cantidad: item.cantidad,
        precioUnitario: item.precioUnitario,
        ...camposCombo(item),
        neto_unitario: desglose.neto,
        iva_unitario: desglose.iva,
        impuestos_internos_unitario: desglose.impuestosInternos,
        porcentaje_iva: pctIva,
      };
    });
    for (const regalo of regalosDelPedido) {
      items.push({
        productoId: String(regalo.producto_id),
        cantidad: Number(regalo.cantidad),
        precioUnitario: 0,
        esBonificacion: true,
        ...(regalo.promocion_id != null ? { promocionId: String(regalo.promocion_id) } : {}),
        neto_unitario: 0,
        iva_unitario: 0,
        impuestos_internos_unitario: 0,
        porcentaje_iva: 0,
      });
    }

    void onConfirmar({
      nuevoClienteId: String(clienteNuevo.id),
      items,
      total,
      totalNeto,
      totalIva,
      motivo: 'Cambio de cliente',
      ...(tienePago && destinoPagos ? { destinoPagos } : {}),
    });
  };

  const nombreProducto = (productoId: string): string =>
    productos.find(p => String(p.id) === String(productoId))?.nombre ?? `Producto #${productoId}`;

  return (
    <ModalBase title="Cambiar cliente" onClose={onClose} maxWidth="max-w-lg">
      <div className="max-h-[70vh] overflow-y-auto overscroll-contain p-4 space-y-4">
        {esVB && (
          <div role="alert" className="p-3 bg-rose-50 border border-rose-300 rounded-lg text-sm text-rose-900 dark:bg-rose-900/30 dark:border-rose-700 dark:text-rose-200">
            {MENSAJE_VB_NO_SE_EDITA}
          </div>
        )}
        {/* Cliente actual */}
        <div>
          <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Cliente actual</p>
          <div className="p-3 bg-gray-50 dark:bg-gray-800 border dark:border-gray-700 rounded-lg">
            <p className="font-medium dark:text-white">{clienteActual?.nombre_fantasia ?? '—'}</p>
            {clienteActual?.direccion && (
              <p className="text-sm text-gray-500 dark:text-gray-400">{clienteActual.direccion}</p>
            )}
          </div>
        </div>

        {/* Nuevo cliente: buscador o seleccionado */}
        <div>
          <p className="text-xs font-medium text-gray-500 dark:text-gray-400 mb-1">Nuevo cliente</p>
          {clienteNuevo ? (
            <div className="p-3 bg-blue-50 dark:bg-blue-900/30 border border-blue-200 dark:border-blue-800 rounded-lg flex justify-between items-center">
              <div className="min-w-0">
                <p className="font-medium dark:text-white truncate">{clienteNuevo.nombre_fantasia}</p>
                {clienteNuevo.direccion && (
                  <p className="text-sm text-gray-500 dark:text-gray-400 truncate">{clienteNuevo.direccion}</p>
                )}
              </div>
              <button
                type="button"
                onClick={() => { setNuevoClienteId(''); setBusquedaCliente(''); }}
                className="text-red-500 p-1 flex-shrink-0"
                aria-label="Quitar cliente seleccionado"
              >
                <X className="w-5 h-5" />
              </button>
            </div>
          ) : (
            <div>
              <div className="relative w-full">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 text-gray-400 w-5 h-5 pointer-events-none" />
                <input
                  type="text"
                  value={busquedaCliente}
                  onChange={e => setBusquedaCliente(e.target.value)}
                  autoComplete="off"
                  className="block w-full pl-10 pr-3 py-3 min-h-11 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none"
                  placeholder="Buscar por nombre, razón social o CUIT..."
                />
              </div>
              {clientesFiltrados.length > 0 && (
                <div role="listbox" aria-label="Resultados de clientes" className="border dark:border-gray-600 rounded-lg max-h-40 overflow-y-auto mt-2">
                  {clientesFiltrados.map(c => (
                    <button
                      type="button"
                      role="option"
                      aria-selected={false}
                      key={c.id}
                      className="w-full text-left p-3 hover:bg-blue-50 dark:hover:bg-blue-900/30 border-b dark:border-gray-600 focus:outline-none focus:bg-blue-100 dark:focus:bg-blue-900/50"
                      onClick={() => { setNuevoClienteId(c.id.toString()); setBusquedaCliente(''); }}
                    >
                      <p className="font-medium dark:text-white">{c.nombre_fantasia}</p>
                      {c.razon_social && c.razon_social !== c.nombre_fantasia && (
                        <p className="text-xs text-gray-400">{c.razon_social}</p>
                      )}
                      <p className="text-sm text-gray-500 dark:text-gray-400">{c.direccion}</p>
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}
        </div>

        {/* Comparación de precios (solo con cliente nuevo elegido) */}
        {clienteNuevo && (
          <div className="space-y-3">
            {isLoading ? (
              <div className="flex items-center justify-center gap-2 py-6 text-gray-500 dark:text-gray-400">
                <Loader2 className="w-5 h-5 animate-spin" />
                <span className="text-sm">Recalculando precios…</span>
              </div>
            ) : (
              <>
                {/* Detalle de items recalculados */}
                <div className="border dark:border-gray-700 rounded-lg divide-y dark:divide-gray-700">
                  {descuento.items.filter(item => !item.esBonificacion).map((item, idx) => (
                    <div key={`${item.productoId}-${idx}`} className="flex items-center justify-between gap-2 p-2.5 text-sm">
                      <div className="min-w-0 flex items-center gap-1.5">
                        <span className="truncate dark:text-gray-200">{nombreProducto(String(item.productoId))}</span>
                      </div>
                      <div className="flex-shrink-0 text-right">
                        <span className="dark:text-gray-200">{item.cantidad} × {formatPrecio(item.precioUnitario)}</span>
                      </div>
                    </div>
                  ))}
                  {regalosDelPedido.map(regalo => (
                    <div key={`regalo-${regalo.id}`} className="flex items-center justify-between gap-2 p-2.5 text-sm">
                      <div className="min-w-0 flex items-center gap-1.5">
                        <Gift className="w-4 h-4 text-green-600 flex-shrink-0" />
                        <span className="truncate dark:text-gray-200">{nombreProducto(String(regalo.producto_id))}</span>
                      </div>
                      <div className="flex-shrink-0 text-right">
                        <span className="text-green-600 font-medium">{Number(regalo.cantidad)} × Regalo</span>
                      </div>
                    </div>
                  ))}
                </div>

                {/* Comparativo de totales */}
                <div className="p-3 bg-gray-50 dark:bg-gray-800 rounded-lg space-y-1.5">
                  <div className="flex items-center justify-between text-sm">
                    <span className="text-gray-500 dark:text-gray-400">Total anterior</span>
                    <span className="text-gray-500 dark:text-gray-400 line-through">{formatPrecio(totalViejo)}</span>
                  </div>
                  <div className="flex items-center justify-between">
                    <span className="font-medium dark:text-white flex items-center gap-1.5">
                      <ArrowRight className="w-4 h-4 text-blue-500" /> Total nuevo
                    </span>
                    <span className="text-lg font-bold dark:text-white">{formatPrecio(totalNuevo)}</span>
                  </div>
                  {Math.abs(delta) >= 0.01 && (
                    <div className={`text-xs text-right font-medium ${delta > 0 ? 'text-red-600' : 'text-green-600'}`}>
                      {delta > 0 ? '+' : ''}{formatPrecio(delta)} respecto al anterior
                    </div>
                  )}
                </div>
              </>
            )}
          </div>
        )}

        {/* Avisos */}
        <div className="flex items-start gap-2 p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg text-xs text-amber-800 dark:text-amber-200">
          <AlertCircle className="w-4 h-4 flex-shrink-0 mt-0.5" />
          <div className="space-y-0.5">
            <p>El pedido actual se <strong>cancelará</strong> y se creará uno nuevo para el cliente elegido. Si estaba asignado a una ruta, saldrá de la ruta.</p>
            <p>La venta sigue siendo de quien la cargó, y el regalo es el mismo.</p>
          </div>
        </div>

        {partesCobro.delCliente > 0.005 && (
          <p className="text-sm text-gray-700 dark:text-gray-300">
            {formatPrecio(partesCobro.delCliente)} de lo pagado vinieron del saldo a favor o de un pago a cuenta del cliente actual: vuelven a él, pagan sus otras boletas impagas (la más vieja primero) y lo que sobre le queda a favor.
          </p>
        )}

        {tienePago && (
          <fieldset className="space-y-2 p-3 border border-gray-200 dark:border-gray-700 rounded-lg">
            <legend className="px-1 text-sm font-medium dark:text-white">
              El pedido tiene {formatPrecio(partesCobro.cobro)} cobrados. ¿Qué pasa con ese pago?
            </legend>
            <label className="flex items-start gap-2 text-sm cursor-pointer dark:text-gray-200">
              <input
                type="radio"
                name="destino-pagos"
                value="pedido_nuevo"
                checked={destinoPagos === 'pedido_nuevo'}
                onChange={() => setDestinoPagos('pedido_nuevo')}
                className="mt-1"
              />
              <span>
                <strong>Fue un error de carga:</strong> el pago pasa al pedido nuevo. Si el total nuevo es menor, lo que sobra queda a favor del cliente nuevo.
              </span>
            </label>
            <label className="flex items-start gap-2 text-sm cursor-pointer dark:text-gray-200">
              <input
                type="radio"
                name="destino-pagos"
                value="cliente_original"
                checked={destinoPagos === 'cliente_original'}
                onChange={() => setDestinoPagos('cliente_original')}
                className="mt-1"
              />
              <span>
                <strong>El cliente no tomó el pedido:</strong> lo que pagó paga sus otras boletas impagas (la más vieja primero), lo que sobre le queda a favor, y el pedido nuevo nace sin cobrar.
              </span>
            </label>
          </fieldset>
        )}
      </div>

      {/* Acciones */}
      <div className="flex gap-2 p-4 border-t dark:border-gray-700">
        <Button
          type="button"
          variant="secondary"
          size="md"
          onClick={onClose}
          disabled={guardando}
          className="flex-1"
        >
          Cancelar
        </Button>
        <Button
          type="button"
          variant="primary"
          size="md"
          onClick={handleConfirmar}
          disabled={!clienteNuevo || isLoading || guardando || esVB || faltaDestino}
          loading={guardando}
          className="flex-1"
        >
          {!guardando && <RefreshCw className="w-4 h-4" />}
          {guardando ? 'Cambiando…' : 'Confirmar cambio'}
        </Button>
      </div>
    </ModalBase>
  );
});

export default ModalCambiarCliente;
