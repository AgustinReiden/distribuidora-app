import { memo } from 'react';
import { Loader2, History } from 'lucide-react';
import ModalBase from './ModalBase';
import { formatFecha } from './utils';
import { formatPrecio, getEstadoPagoLabel } from '../../utils/formatters';
import { parsePrecio } from '../../utils/calculations';
import { Badge } from '../ui/Badge';
import { toneDeEstadoPedido, toneDeEstadoPago, type Tone } from '../../lib/estadoTones';
import {
  parsearLineasHistorial,
  compararItemsHistorial,
  type FilaHistorialItems,
  type CambioLineaHistorial,
} from '../../utils/historialItems';
import type { PedidoDB } from '../../types';

// =============================================================================
// TIPOS
// =============================================================================

/** Registro de cambio en historial */
export interface HistorialCambio {
  id?: string;
  campo_modificado: string;
  valor_anterior: string;
  valor_nuevo: string;
  created_at?: string;
  usuario?: {
    nombre: string;
  } | null;
}

/** Props del componente principal */
export interface ModalHistorialPedidoProps {
  pedido: PedidoDB | null;
  historial: HistorialCambio[];
  onClose: () => void;
  loading: boolean;
  /** Transportistas activos para resolver el UUID guardado en el historial a un nombre legible. */
  transportistas?: Array<{ id: string; nombre: string }>;
  /** Para mostrar el nombre de cada producto del historial de items; sin ella se ve "Producto #id". */
  productos?: Array<{ id: string | number; nombre: string }>;
}

const ESTILO_FILA: Record<FilaHistorialItems['estado'], { marca: string; texto: string; fila: string }> = {
  agregado: { marca: '+', texto: 'Agregado', fila: 'text-green-700' },
  quitado: { marca: '−', texto: 'Quitado', fila: 'text-red-700' },
  cambiado: { marca: '~', texto: 'Modificado', fila: 'text-gray-900' },
  igual: { marca: '', texto: 'Sin cambios', fila: 'text-gray-500' },
};

function DetalleCambio({ cambio }: { cambio: CambioLineaHistorial }) {
  if (cambio.campo === 'cantidad') return <span>Cant. {cambio.antes} → {cambio.despues}</span>;
  if (cambio.campo === 'precio') return <span>Precio {formatPrecio(cambio.antes)} → {formatPrecio(cambio.despues)}</span>;
  return (
    <span className="block break-words">
      Descripción: {cambio.antes ?? 'sin descripción'} → {cambio.despues ?? 'sin descripción'}
    </span>
  );
}

/** Mapa de campos a etiquetas */
type CampoMapeo = Record<string, string>;

const ModalHistorialPedido = memo(function ModalHistorialPedido({ pedido, historial, onClose, loading, transportistas = [], productos = [] }: ModalHistorialPedidoProps) {
  // Resuelve el UUID del transportista (guardado como texto en el historial) a
  // su nombre. 'sin asignar' es el literal que escribe el trigger cuando no hay
  // transportista. Si no se encuentra (transportista dado de baja), cae al UUID.
  const resolverTransportista = (valor: string): string => {
    if (!valor || valor === 'sin asignar') return 'Sin asignar';
    return transportistas.find(t => String(t.id) === String(valor))?.nombre || valor;
  };

  const formatearCampo = (campo: string): string => {
    const mapeo: CampoMapeo = {
      estado: "Estado",
      transportista_id: "Transportista",
      notas: "Notas",
      forma_pago: "Forma de pago",
      estado_pago: "Estado de pago",
      total: "Total",
      creacion: "Creacion",
      sustitucion_regalo: "Sustitucion de regalo",
      items: "Items",
      tipo_factura: "Comprobante"
    };
    return mapeo[campo] || campo;
  };

  const formatearValor = (campo: string, valor: string): string => {
    if (campo === "transportista_id") return resolverTransportista(valor);
    if (campo === "total") return formatPrecio(parsePrecio(valor));
    if (campo === "estado") {
      const estados: Record<string, string> = { pendiente: "Pendiente", en_preparacion: "En preparación", asignado: "En camino", entregado: "Entregado", cancelado: "Cancelado" };
      return estados[valor] || valor;
    }
    if (campo === "estado_pago") return getEstadoPagoLabel(valor);
    // La migración del histórico escribe 'VB (vale blanco pasa de forma de
    // pago a comprobante)': ése ya se explica solo y va tal cual.
    if (campo === "tipo_factura") return valor === "VB" ? "VB (vale blanco)" : valor;
    if (campo === "forma_pago") {
      const formas: Record<string, string> = {
        efectivo: "Efectivo",
        transferencia: "Transferencia",
        cheque: "Cheque",
        cuenta_corriente: "Cuenta Corriente",
        tarjeta: "Tarjeta"
      };
      return formas[valor] || valor;
    }
    return valor;
  };

  const nombreProducto = (id: string): string =>
    productos.find(p => String(p.id) === id)?.nombre || `Producto #${id}`;

  const renderItems = (cambio: HistorialCambio) => {
    const anterior = parsearLineasHistorial(cambio.valor_anterior);
    const nuevo = parsearLineasHistorial(cambio.valor_nuevo);
    // Si alguno de los dos lados no se puede leer, se muestra el texto tal cual
    // pero cortando línea, para que no desborde el modal.
    if (!anterior || !nuevo) {
      return (
        <div className="flex items-center gap-2 text-sm flex-wrap min-w-0">
          <span className="min-w-0 break-words whitespace-normal rounded-lg bg-gray-100 px-2.5 py-1 text-gray-700">{cambio.valor_anterior}</span>
          <span className="text-gray-400">→</span>
          <span className="min-w-0 break-words whitespace-normal rounded-lg bg-gray-100 px-2.5 py-1 text-gray-700">{cambio.valor_nuevo}</span>
        </div>
      );
    }
    const filas = compararItemsHistorial(anterior, nuevo);
    if (filas.length === 0) return <p className="text-sm text-gray-500">Sin líneas</p>;
    return (
      <ul className="space-y-1.5 text-sm min-w-0">
        {filas.map((f, i) => {
          const estilo = ESTILO_FILA[f.estado];
          return (
            <li key={`${f.productoId}-${f.esBonificacion}-${i}`} className={`flex gap-2 min-w-0 ${estilo.fila}`}>
              <span aria-hidden="true" className="w-3 shrink-0 text-center font-bold">{estilo.marca}</span>
              <div className="min-w-0 flex-1">
                <p className="break-words">
                  <span className="sr-only">{estilo.texto}: </span>
                  <span className={`font-medium ${f.estado === 'quitado' ? 'line-through' : ''}`}>{nombreProducto(f.productoId)}</span>
                  {' '}
                  <span>x{f.linea.cantidad}</span>
                  {f.esBonificacion && (
                    <Badge tone="warning" className="ml-1.5">Regalo</Badge>
                  )}
                  {f.estado !== 'cambiado' && f.estado !== 'igual' && (
                    <span className="ml-1.5 text-xs font-semibold" aria-hidden="true">{estilo.texto}</span>
                  )}
                </p>
                {f.estado === 'cambiado' && (
                  <p className="break-words text-xs font-medium text-amber-700">
                    <span className="sr-only">Modificado: </span>
                    {f.cambios.map(c => (
                      <span key={c.campo} className="block">
                        <DetalleCambio cambio={c} />
                      </span>
                    ))}
                  </p>
                )}
                {f.estado !== 'cambiado' && f.linea.descripcionRegalo && (
                  <p className="break-words text-xs text-gray-500">{f.linea.descripcionRegalo}</p>
                )}
              </div>
            </li>
          );
        })}
      </ul>
    );
  };

  // Tono del badge según el valor, usando el mismo mapa estado -> tono que la
  // tarjeta de pedido (toneDeEstadoPedido / toneDeEstadoPago). Para el resto de
  // los campos (total, notas, forma de pago, transportista) el neutro por defecto.
  const toneValor = (campo: string, valor: string): Tone => {
    if (campo === "estado") return toneDeEstadoPedido(valor);
    if (campo === "estado_pago") return toneDeEstadoPago(valor);
    return "neutral";
  };

  return (
    <ModalBase title={`Historial de cambios - Pedido #${pedido?.id}`} onClose={onClose} maxWidth="max-w-2xl">
      <div className="p-4">
        {loading ? (
          <div className="flex justify-center py-8">
            <Loader2 className="w-8 h-8 animate-spin text-blue-600" />
          </div>
        ) : historial.length === 0 ? (
          <div className="text-center py-8 text-gray-500">
            <History className="w-12 h-12 mx-auto mb-3 opacity-50" />
            <p>No hay cambios registrados para este pedido</p>
          </div>
        ) : (
          <div className="space-y-3 max-h-96 overflow-y-auto">
            {historial.map((cambio, index) => (
              <div key={cambio.id || index} className="border rounded-lg p-3 bg-gray-50">
                <div className="flex justify-between items-start mb-2">
                  <div>
                    <p className="font-medium text-gray-900">
                      {formatearCampo(cambio.campo_modificado)}
                    </p>
                    <p className="text-sm text-gray-600">
                      {cambio.usuario?.nombre || "Sistema"}
                    </p>
                  </div>
                  <p className="text-xs text-gray-500">{cambio.created_at ? formatFecha(cambio.created_at) : '-'}</p>
                </div>
                {cambio.campo_modificado === "creacion" ? (
                  <p className="text-sm text-green-600 font-medium">{cambio.valor_nuevo}</p>
                ) : cambio.campo_modificado === "items" ? (
                  renderItems(cambio)
                ) : (
                  <div className="flex items-center gap-2 text-sm flex-wrap">
                    <Badge tone={toneValor(cambio.campo_modificado, cambio.valor_anterior)} className="px-2.5 py-1">
                      {formatearValor(cambio.campo_modificado, cambio.valor_anterior)}
                    </Badge>
                    <span className="text-gray-400">→</span>
                    <Badge tone={toneValor(cambio.campo_modificado, cambio.valor_nuevo)} className="px-2.5 py-1">
                      {formatearValor(cambio.campo_modificado, cambio.valor_nuevo)}
                    </Badge>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
      <div className="flex justify-end p-4 border-t bg-gray-50">
        <button onClick={onClose} className="px-4 py-2 bg-gray-600 text-white rounded-lg hover:bg-gray-700">
          Cerrar
        </button>
      </div>
    </ModalBase>
  );
});

export default ModalHistorialPedido;
