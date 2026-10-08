/**
 * Tarjeta de un pedido en la lista de /pedidos (WP-43, #768).
 *
 * Dos líneas y un riel:
 *  - Riel de color a la izquierda (`Card` con `accent`): el tono del estado.
 *  - Línea 1: estado, cliente, estado de pago y total.
 *  - Línea 2: #id, FC/ZZ/VB, dirección, deuda previa del cliente, entrega,
 *    vendedor → transportista y cantidad de ítems. Cada dato con su ícono.
 *  - A la derecha: UNA acción visible (la que el estado está esperando, elegida
 *    entre las que YA ofrece el menú ⋮), el recibo si está pagado, el menú ⋮ con
 *    todas las acciones, y el chevron que abre el detalle.
 *  - Detalle: fecha y hora de carga, antigüedad, GPS, cliente completo, todos
 *    los ítems con sus salvedades, forma y desglose de pago, motivo de
 *    cancelación y notas.
 *
 * Los handlers llegan por props. Hubo un intento de pasarlos por contexto
 * (HandlersContext) que nunca se terminó y se retiró.
 */
import React, { useState, useRef, useEffect, memo } from 'react';
import {
  AlertTriangle,
  Banknote,
  Building2,
  Calendar,
  CheckCircle2,
  ChevronDown,
  Clock,
  CreditCard,
  FileDown,
  FileText,
  Gift,
  MapPin,
  Package,
  Phone,
  RefreshCw,
  Timer,
  Truck,
  User,
  XCircle,
  type LucideIcon,
} from 'lucide-react';
import { importConRecarga } from '../../utils/lazyWithReload';
const generarReciboPedido = async (pedido: any, _empresa: any = {}, options: { formato?: 'a4' | 'comanda'; rol?: RolUsuario | null } = {}) => {
  const mod = await importConRecarga(() => import('../../lib/pdfExport')) as any
  return mod.generarReciboPedido(pedido, _empresa, options)
};
import { formatPrecio, formatFecha, formatHora, fechaLocalISO, parseDateSafe, getEstadoLabel, getEstadoPagoLabel, getFormaPagoLabel, getFormaPagoDisplay } from '../../utils/formatters';
import { MOTIVOS_SALVEDAD_LABELS } from '../../lib/schemas';
import { Badge } from '../ui/Badge';
import { Button } from '../ui/Button';
import Card from '../ui/Card';
import { toneDeEstadoPago, toneDeEstadoPedido, type Tone } from '../../lib/estadoTones';
import AccionesDropdown from './PedidoActions';
import {
  construirAccionesPedido,
  elegirAccionPrincipal,
  type ContextoAccionesPedido,
  type HandlersAccionesPedido,
} from '../../utils/accionPrincipalPedido';
import { useCambiarTipoFacturaMutation } from '../../hooks/queries/usePedidosQuery';
import { useAuthData } from '../../contexts/AuthDataContext';
import { useNotification } from '../../contexts';
import { haversineMeters, formatDistancia, clasificarDistancia, SEMAFORO_COLORS, type ClasificacionDistancia } from '../../utils/geo';
import { avisoDeudaCliente } from '../../utils/deudaCliente';
import { puedeVerDeudaCliente, puedeVerPreciosLineaPedido } from '../../lib/permisos';
import { formatCantidadItem, equivalenteEnUnidades } from '../../utils/unidadesRegalo';
import type { PedidoDB, MotivoSalvedad, RolUsuario, TipoComprobanteVenta } from '../../types';
import {
  destinosTipoFactura,
  esTipoVB,
  mensajeConversionTipoFactura,
  ETIQUETA_BADGE_VB,
  ETIQUETA_CONSUMO_INTERNO,
} from '../../utils/valeBlanco';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface BadgeAntiguedadProps {
  dias: number;
  estado: PedidoDB['estado'];
}

export interface PedidoCardProps {
  pedido: PedidoDB;
  isAdmin?: boolean;
  isPreventista?: boolean;
  isTransportista?: boolean;
  isEncargado?: boolean;
  onVerHistorial?: (pedido: PedidoDB) => void;
  onEditarPedido?: (pedido: PedidoDB) => void;
  onEditarNotas?: (pedido: PedidoDB) => void;
  onMarcarEnPreparacion?: (pedido: PedidoDB) => void;
  onVolverAPendiente?: (pedido: PedidoDB) => void;
  onMarcarEntregado?: (pedido: PedidoDB) => void;
  onMarcarEntregadoConSalvedad?: (pedido: PedidoDB) => void;
  onDesmarcarEntregado?: (pedido: PedidoDB) => void;
  onCancelarPedido?: (pedido: PedidoDB) => void;
  onRegistrarPago?: (pedido: PedidoDB) => void;
  /** Nota de crédito de venta sobre un pedido entregado (#833). */
  onNotaCreditoVenta?: (pedido: PedidoDB) => void;
  /**
   * Timestamp del fetch que trajo estos pedidos (`dataUpdatedAt`). Solo se usa
   * sin conexion, para fechar la deuda en el aviso: el numero es el del ultimo
   * sync y no incluye lo cobrado despues.
   */
  saldoActualizadoAt?: number | null;
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// Funcion para calcular dias de antiguedad de un pedido
function calcularDiasAntiguedad(fechaCreacion: string | undefined): number {
  if (!fechaCreacion) return 0;
  // Para fechas date-only (YYYY-MM-DD), agregar T12:00:00 para evitar
  // que JS las interprete como UTC medianoche (causa dia anterior en UTC-)
  const fecha = typeof fechaCreacion === 'string' && /^\d{4}-\d{2}-\d{2}$/.test(fechaCreacion)
    ? new Date(fechaCreacion + 'T12:00:00')
    : new Date(fechaCreacion);
  const hoy = new Date();
  const diffTime = hoy.getTime() - fecha.getTime();
  return Math.floor(diffTime / (1000 * 60 * 60 * 24));
}

interface EstadoVisual {
  label: string;
  icon: LucideIcon;
  /** Tooltip del badge, cuando el texto solo no alcanza. */
  titulo?: string;
}

/**
 * Texto e ícono del badge de estado. El texto es el mismo vocabulario que usan
 * los filtros y los KPIs de /pedidos ("En camino" para `asignado`). El color no
 * sale de acá: es `toneDeEstadoPedido`, el mismo que pinta el riel.
 */
const ESTADO_VISUAL: Partial<Record<PedidoDB['estado'], EstadoVisual>> = {
  pendiente: { label: 'Pendiente', icon: Clock },
  en_preparacion: { label: 'En preparación', icon: Package },
  asignado: { label: 'En camino', icon: Truck },
  en_camino: { label: 'En camino', icon: Truck },
  entregado: { label: 'Entregado', icon: CheckCircle2 },
  cancelado: { label: 'Cancelado', icon: XCircle },
};

function estadoVisual(pedido: PedidoDB, tieneSalvedad: boolean): EstadoVisual {
  // Mismo texto que el último paso del stepper que había antes: la entrega con
  // salvedad se distingue de una entrega limpia.
  if (pedido.estado === 'entregado' && tieneSalvedad) {
    return { label: 'Con Salvedad', icon: AlertTriangle, titulo: 'Entregado con salvedad' };
  }
  const visual = ESTADO_VISUAL[pedido.estado] ?? { label: getEstadoLabel(pedido.estado), icon: Clock };
  // El motivo completo está en el detalle; en el badge queda a mano como tooltip.
  if (pedido.estado === 'cancelado' && pedido.motivo_cancelacion) {
    return { ...visual, titulo: `Cancelado: ${pedido.motivo_cancelacion}` };
  }
  return visual;
}

/** Semáforo del GPS en los tonos del Badge (que ya traen su variante oscura). */
const TONO_SEMAFORO: Record<ClasificacionDistancia, Tone> = {
  ok: 'success',
  cerca: 'warning',
  lejos: 'danger',
  sin_dato: 'neutral',
};

// =============================================================================
// SUB-COMPONENTS
// =============================================================================

const MENSAJE_ERROR_TIPO_FACTURA = 'No se pudo cambiar el tipo de factura';

/**
 * Badge del comprobante (FC/ZZ/VB) del pedido. Los destinos a los que se puede
 * pasar salen de `destinosTipoFactura` (N10 del vale blanco: rol, estado,
 * cliente habilitado). Con UN solo destino posible se comporta como siempre:
 * primer click arma la confirmación inline, segundo click ejecuta vía RPC
 * cambiar_tipo_factura_pedido. Con más de uno (cliente habilitado para vale
 * blanco, o un VB en manos del admin) el primer click abre la lista de
 * destinos; elegir uno arma la confirmación y el segundo click la ejecuta. Un
 * destino bloqueado se ve deshabilitado y con el motivo.
 *
 * ZZ ↔ FC: el total no cambia, solo se redistribuye neto/IVA. Hacia o desde VB
 * el servidor re-precia (a costo o a lista).
 */
function BadgeTipoFactura({ pedido, isAdmin, isEncargado }: {
  pedido: PedidoDB;
  isAdmin?: boolean;
  isEncargado?: boolean;
}): React.ReactElement | null {
  const cambiarTipo = useCambiarTipoFacturaMutation();
  const notify = useNotification();
  const [confirmando, setConfirmando] = useState<TipoComprobanteVenta | null>(null);
  const [menuAbierto, setMenuAbierto] = useState(false);
  // El timer que desarma la confirmación a los 3 s. Se guarda para poder
  // cancelarlo: uno suelto desarmaba, a destiempo, una confirmación posterior.
  const timerConfirmacion = useRef<ReturnType<typeof setTimeout> | null>(null);
  const cancelarTimerConfirmacion = (): void => {
    if (timerConfirmacion.current !== null) {
      clearTimeout(timerConfirmacion.current);
      timerConfirmacion.current = null;
    }
  };
  // Al desmontar (la lista se refresca o filtra) no queda un timer apuntando a
  // un estado que ya no existe.
  useEffect(() => () => {
    if (timerConfirmacion.current !== null) clearTimeout(timerConfirmacion.current);
  }, []);
  const tipo = (pedido.tipo_factura ?? 'ZZ') as string;
  const esVB = esTipoVB(tipo);
  const destinos = destinosTipoFactura(pedido, { isAdmin, isEncargado });
  const destinosElegibles = destinos.filter(d => !d.bloqueo);
  // Un solo destino posible y ninguno bloqueado: el flip de siempre.
  const flipDirecto = destinos.length === 1 && destinosElegibles.length === 1
    ? destinosElegibles[0].tipo
    : null;

  const claseBase = tipo === 'FC'
    ? 'bg-blue-100 text-blue-700 dark:bg-blue-900/40 dark:text-blue-300'
    : esVB
      ? 'bg-violet-100 text-violet-800 dark:bg-violet-900/40 dark:text-violet-200'
      // ZZ un tono más oscuro que el resto de los grises: con gray-500 el texto
      // bold de 12 px quedaba en 4,4:1 sobre su fondo (WP-43).
      : 'bg-gray-100 text-gray-600 dark:bg-gray-700 dark:text-gray-300';
  const etiqueta = esVB ? ETIQUETA_BADGE_VB : tipo;

  if (destinos.length === 0) {
    // Solo lectura: FC y VB se ven siempre; ZZ (el default) no se dibuja.
    if (tipo !== 'FC' && !esVB) return null;
    return (
      <span className={`px-2 py-0.5 rounded text-xs font-bold tracking-wider ${claseBase}`}>{etiqueta}</span>
    );
  }

  const armar = (destino: TipoComprobanteVenta): void => {
    setConfirmando(destino);
    setMenuAbierto(false);
    cancelarTimerConfirmacion();
    timerConfirmacion.current = setTimeout(() => {
      timerConfirmacion.current = null;
      setConfirmando(null);
    }, 3000);
  };

  const ejecutar = async (destino: TipoComprobanteVenta): Promise<void> => {
    cancelarTimerConfirmacion();
    setConfirmando(null);
    try {
      await cambiarTipo.mutateAsync({ pedidoId: String(pedido.id), tipo: destino });
      const aviso = mensajeConversionTipoFactura(tipo, destino);
      if (aviso) notify.success(aviso, { persist: true });
    } catch (err) {
      // La mutation no tiene onError y no hay un MutationCache global que
      // avise: sin esto el badge vuelve a su tipo de antes sin decir por qué.
      // El motivo de la RPC ("La rendición del día está cerrada") es lo que
      // le sirve a quien lo intentó.
      const motivo = err instanceof Error ? err.message : '';
      notify.error(motivo && motivo !== MENSAJE_ERROR_TIPO_FACTURA
        ? `${MENSAJE_ERROR_TIPO_FACTURA}: ${motivo}`
        : MENSAJE_ERROR_TIPO_FACTURA);
    }
  };

  const claseBoton = 'px-2 py-0.5 rounded text-xs font-bold tracking-wider transition-colors disabled:opacity-50';
  const claseArmado = 'bg-amber-100 text-amber-700 ring-1 ring-amber-400 dark:bg-amber-900/40 dark:text-amber-300 dark:ring-amber-500';

  return (
    <span className="inline-flex flex-wrap items-center gap-1">
      <button
        type="button"
        disabled={cambiarTipo.isPending}
        aria-expanded={flipDirecto ? undefined : menuAbierto}
        title={confirmando
          ? `Confirmar cambio a ${confirmando}`
          : flipDirecto
            ? `Cambiar a ${flipDirecto}${esVB || flipDirecto === 'VB' ? '' : ' (el total no cambia)'}`
            : 'Cambiar el comprobante'}
        onClick={async () => {
          if (confirmando) {
            await ejecutar(confirmando);
            return;
          }
          if (flipDirecto) {
            armar(flipDirecto);
            return;
          }
          setMenuAbierto(v => !v);
        }}
        className={`${claseBoton} ${
          confirmando
            ? claseArmado
            : `${claseBase} hover:ring-1 hover:ring-blue-300 dark:hover:ring-blue-500`
        }`}
      >
        {cambiarTipo.isPending ? '…' : confirmando ? `→ ${confirmando}?` : etiqueta}
      </button>
      {menuAbierto && !confirmando && destinos.map(d => (
        <button
          key={d.tipo}
          type="button"
          disabled={!!d.bloqueo || cambiarTipo.isPending}
          title={d.bloqueo ?? `Pasar a ${d.tipo}`}
          onClick={() => armar(d.tipo)}
          className={`${claseBoton} bg-white text-gray-700 ring-1 ring-gray-300 hover:bg-gray-50 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-600 dark:hover:bg-gray-700 disabled:cursor-not-allowed`}
        >
          → {d.tipo}
        </button>
      ))}
    </span>
  );
}

// Componente de badge de antiguedad. Es la alarma de "esto lleva dias sin
// entregarse": un entregado ya se entrego y un cancelado ya no se va a entregar.
function BadgeAntiguedad({ dias, estado }: BadgeAntiguedadProps): React.ReactElement | null {
  if (estado === 'entregado' || estado === 'cancelado' || dias < 2) return null;

  return (
    <Badge tone={dias >= 3 ? 'danger' : 'warning'} icon={Timer} title="Días desde la carga">
      {dias}d
    </Badge>
  );
}

// Badge: distancia entre el GPS del check-in del preventista y la dirección
// del cliente. Solo se muestra a admin (y al preventista dueño). Si no hubo
// check-in (gps_status null), no renderiza nada para no contaminar las cards
// históricas previas a la migración 040.
interface BadgeGeolocalizacionProps {
  pedido: PedidoDB;
}

function BadgeGeolocalizacion({ pedido }: BadgeGeolocalizacionProps): React.ReactElement | null {
  if (!pedido.gps_status) return null;

  // GPS fallido: mostrar chip neutro indicando el motivo.
  if (pedido.gps_status !== 'ok') {
    const motivo =
      pedido.gps_status === 'denied' ? 'GPS denegado' :
      pedido.gps_status === 'timeout' ? 'GPS sin respuesta' :
      pedido.gps_status === 'unavailable' ? 'GPS no disponible' :
      'GPS con error';
    return (
      <Badge tone="neutral" icon={MapPin} title={motivo}>
        Sin GPS
      </Badge>
    );
  }

  // GPS ok: si el cliente no tiene coordenadas, no podemos calcular distancia.
  const clienteLat = pedido.cliente?.latitud;
  const clienteLng = pedido.cliente?.longitud;
  const pedidoLat = pedido.gps_lat;
  const pedidoLng = pedido.gps_lng;

  if (clienteLat == null || clienteLng == null || pedidoLat == null || pedidoLng == null) {
    return (
      <Badge tone="neutral" icon={MapPin} title="Cliente sin coordenadas cargadas">
        s/ref
      </Badge>
    );
  }

  const metros = haversineMeters(
    { lat: Number(pedidoLat), lng: Number(pedidoLng) },
    { lat: Number(clienteLat), lng: Number(clienteLng) },
  );
  const clasif = clasificarDistancia(metros);
  const cfg = SEMAFORO_COLORS[clasif];

  return (
    <Badge tone={TONO_SEMAFORO[clasif]} icon={MapPin} title={`${cfg.label} · ${formatDistancia(metros)}`}>
      {formatDistancia(metros)}
    </Badge>
  );
}

// =============================================================================
// MAIN COMPONENT
// =============================================================================

function PedidoCard({
  pedido,
  isAdmin,
  isPreventista,
  isTransportista,
  isEncargado,
  onVerHistorial,
  onEditarPedido,
  onEditarNotas,
  onMarcarEnPreparacion,
  onVolverAPendiente,
  onMarcarEntregado,
  onMarcarEntregadoConSalvedad,
  onDesmarcarEntregado,
  onCancelarPedido,
  onRegistrarPago,
  onNotaCreditoVenta,
  saldoActualizadoAt,
}: PedidoCardProps): React.ReactElement {
  const [expandido, setExpandido] = useState<boolean>(false);
  const tieneSalvedad = Boolean(pedido.salvedades && pedido.salvedades.length > 0);

  const { user, perfil, isOnline } = useAuthData();
  const notify = useNotification();

  // Deuda que el cliente ya tenia ANTES de este pedido. Viene calculada de la
  // base (`deuda_previa`, mig 215) y NO se deriva de `cliente.saldo_cuenta`:
  // ese es el saldo de HOY, e incluye este pedido y los posteriores. Derivarlo
  // fue el bug del PR #530 --cada pedido nuevo inflaba el aviso de las tarjetas
  // viejas del mismo cliente-- y por eso el numero se calcula donde estan los
  // pedidos anteriores, no aca.
  // El gate por rol se evalua contra `perfil.rol` (rol primario) y no contra las
  // props isAdmin/isPreventista: VirtualizedPedidoList no pasa `isEncargado`, y
  // el badge tiene que decidirse igual desde las dos listas que montan la card.
  const avisoDeuda = puedeVerDeudaCliente(perfil?.rol)
    ? avisoDeudaCliente(pedido.deuda_previa, {
        saldoAl: !isOnline && saldoActualizadoAt ? formatFecha(new Date(saldoActualizadoAt)) : null,
      })
    : null;

  // Impresión de comanda individual (ticket 75mm). Autocontenido: reusa la misma
  // utilidad que el ReciboDropdown; solo necesita el pedido y su cliente.
  const handleImprimirComanda = React.useCallback(async (p: PedidoDB): Promise<void> => {
    if (p.cliente) {
      await generarReciboPedido(p, p.cliente, { formato: 'comanda', rol: perfil?.rol });
    } else {
      notify.error('No se puede imprimir: el pedido no tiene cliente cargado.');
    }
  }, [notify, perfil?.rol]);

  // Quién mira y qué puede hacer: UN solo par de objetos que reciben tanto el
  // menú ⋮ como la elección de la acción visible. Así el botón de afuera es,
  // por construcción, un ítem que el menú le ofrece a este mismo usuario.
  const contextoAcciones: ContextoAccionesPedido = {
    isAdmin,
    isPreventista,
    isTransportista,
    isEncargado,
    currentUserId: user?.id,
  };
  const handlersAcciones: HandlersAccionesPedido = {
    onHistorial: onVerHistorial,
    onEditar: onEditarPedido,
    onEditarNotas,
    onPreparar: onMarcarEnPreparacion,
    onVolverAPendiente,
    onEntregado: onMarcarEntregado,
    onEntregadoConSalvedad: onMarcarEntregadoConSalvedad,
    onRevertir: onDesmarcarEntregado,
    onCancelarPedido,
    onRegistrarPago,
    onImprimirComanda: handleImprimirComanda,
    onNotaCreditoVenta,
  };
  const accionPrincipal = elegirAccionPrincipal(
    pedido.estado,
    construirAccionesPedido(pedido, contextoAcciones, handlersAcciones),
  );
  const IconoAccionPrincipal = accionPrincipal?.icon;

  const diasAntiguedad = calcularDiasAntiguedad(pedido.fecha || pedido.created_at);
  const fechaCreacionLabel = formatFecha(pedido.fecha || pedido.created_at);
  const horaCreacion = pedido.created_at ? formatHora(pedido.created_at) : null;
  const mostrarEntrega = pedido.fecha_entrega_programada
    && pedido.estado !== 'entregado'
    && pedido.estado !== 'cancelado';
  const mostrarEntregado = pedido.estado === 'entregado' && pedido.fecha_entrega;
  const puedeVerGps = isAdmin || (isPreventista && user?.id === pedido.usuario_id);
  const estado = estadoVisual(pedido, tieneSalvedad);
  // La entrega con salvedad va en ámbar y no en verde, en el badge y en el riel:
  // hubo mercadería que no llegó y puede quedar algo por resolver. Es el color
  // que tenía el último paso del stepper de antes para este caso.
  const tonoEstado: Tone = pedido.estado === 'entregado' && tieneSalvedad
    ? 'warning'
    : toneDeEstadoPedido(pedido.estado);
  const nombreCliente = pedido.cliente?.nombre_fantasia || 'Sin cliente';
  // Vale blanco: consumo interno, saldado por naturaleza y sin pagos. Nunca se
  // muestra "Pagado"/"Pendiente" ni una forma de pago: no hubo cobro.
  const esVB = esTipoVB(pedido.tipo_factura);
  // En un VB el precio de cada línea es el costo del producto: al preventista se
  // le oculta por línea (precio c/u, subtotal, monto de salvedad) y ve sólo el
  // total. Decisión del dueño, 2026-10-08.
  const verPreciosLinea = puedeVerPreciosLineaPedido(perfil?.rol, pedido.tipo_factura);
  const cantidadItems = pedido.items?.length;
  const idDetalle = `pedido-detalle-${pedido.id}`;

  return (
    <Card padding="none" accent={tonoEstado} interactive>
      {/* En celular, datos y acciones comparten fila mientras entren; si no,
          las acciones bajan a su propia fila a la derecha (flex-wrap + basis):
          el total y la acción visible no se pierden nunca por falta de ancho. */}
      <div className="flex flex-wrap items-start gap-x-3 gap-y-2 px-4 py-3">
        <div className="min-w-0 grow basis-48 space-y-1.5">
          {/* ══ LÍNEA 1: estado · cliente · pago · total ══ */}
          <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
            <Badge tone={tonoEstado} icon={estado.icon} title={estado.titulo}>
              {estado.label}
            </Badge>
            <h3
              className="min-w-0 grow basis-32 truncate text-base font-semibold leading-tight text-gray-900 dark:text-white"
              title={nombreCliente}
            >
              {nombreCliente}
            </h3>
            {/* Envuelve en vez de encogerse: a 375 px, sin acción visible, la
                columna de datos comparte fila con el ⋮ y queda angosta; ni el
                badge ni el total (con espacio duro) se pueden partir, así que el
                total baja debajo del badge en vez de salirse de la tarjeta. */}
            <div className="ml-auto flex min-w-0 max-w-full flex-wrap items-center justify-end gap-x-2 gap-y-1">
              {esVB ? (
                <Badge tone="neutral" icon={Banknote} title="Vale blanco: consumo interno a costo, no es deuda">
                  {ETIQUETA_CONSUMO_INTERNO}
                </Badge>
              ) : pedido.estado_pago && (
                <Badge tone={toneDeEstadoPago(pedido.estado_pago)} icon={Banknote}>
                  {getEstadoPagoLabel(pedido.estado_pago)}
                </Badge>
              )}
              <span className="text-lg font-extrabold leading-none tracking-tight tabular-nums text-blue-700 dark:text-blue-300">
                <span className="sr-only">Total </span>
                {formatPrecio(pedido.total)}
              </span>
            </div>
          </div>

          {/* ══ LÍNEA 2: #id · FC/ZZ · dirección · deuda · entrega · personas · ítems ══ */}
          <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-sm text-gray-600 dark:text-gray-400">
            <span className="font-semibold tabular-nums text-gray-700 dark:text-gray-300">#{pedido.id}</span>
            <BadgeTipoFactura pedido={pedido} isAdmin={isAdmin} isEncargado={isEncargado} />
            {pedido.cliente?.direccion && (
              // max-w-full + truncate: una dirección larga ocupa su fila y se
              // corta con puntos suspensivos; entera está en el detalle.
              <span className="inline-flex min-w-0 max-w-full items-center gap-1">
                <MapPin className="h-3.5 w-3.5 flex-shrink-0 text-gray-400 dark:text-gray-500" aria-hidden="true" />
                <span className="truncate">{pedido.cliente.direccion}</span>
              </span>
            )}
            {/* Deuda que el cliente traia de antes de este pedido. Va entre los
                datos del cliente y no junto al badge de pago porque habla del
                CLIENTE, no del pedido: ahi se leeria como el estado de pago de
                este pedido. Es informativo: no bloquea nada. */}
            {avisoDeuda && (
              <Badge tone="danger" icon={AlertTriangle} title={avisoDeuda.detalle}>
                <span className="tabular-nums">{avisoDeuda.etiqueta}</span>
              </Badge>
            )}
            {mostrarEntrega && (
              <span className="inline-flex items-center gap-1 font-medium text-orange-700 dark:text-orange-400" title="Entrega programada">
                <Clock className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                entrega {formatFecha(pedido.fecha_entrega_programada)}
              </span>
            )}
            {mostrarEntregado && (
              // Sólo el día: `fecha_entrega` es una fecha guardada como
              // timestamptz al mediodía AR (usePedidosQuery y las RPC de
              // entrega), así que la hora que traería no es la de la entrega.
              <span className="inline-flex items-center gap-1" title="Fecha de entrega">
                <Clock className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                entregado {formatFecha(fechaLocalISO(parseDateSafe(pedido.fecha_entrega as string)))}
              </span>
            )}
            {/* Cuánto se cobró de un pago parcial: a la vista, no en el detalle,
                porque es lo que mira el que sale a cobrar el resto. */}
            {!esVB && pedido.estado_pago === 'parcial' && (
              <span className="inline-flex items-center gap-1 font-medium tabular-nums text-amber-700 dark:text-amber-400" title="Pago parcial">
                <Banknote className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                Pagado: {formatPrecio(pedido.monto_pagado || 0)} de {formatPrecio(pedido.total)}
              </span>
            )}
            {(pedido.usuario?.nombre || pedido.transportista) && (
              <span className="inline-flex min-w-0 flex-wrap items-center gap-1">
                {pedido.usuario?.nombre && (
                  <span className="inline-flex items-center gap-1" title="Pedido cargado por">
                    <User className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                    <span className="font-medium">{pedido.usuario.nombre}</span>
                  </span>
                )}
                {pedido.usuario?.nombre && pedido.transportista && (
                  <span className="text-gray-500 dark:text-gray-400" aria-hidden="true">→</span>
                )}
                {pedido.transportista && (
                  <span className="inline-flex items-center gap-1" title="Transportista asignado">
                    <Truck className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                    <span className="font-medium">{pedido.transportista.nombre}</span>
                  </span>
                )}
              </span>
            )}
            {cantidadItems !== undefined && (
              <span className="inline-flex items-center gap-1" title="Cantidad de ítems">
                <Package className="h-3.5 w-3.5 flex-shrink-0" aria-hidden="true" />
                {cantidadItems} {cantidadItems === 1 ? 'ítem' : 'ítems'}
              </span>
            )}
          </div>
        </div>

        {/* ══ ACCIONES: la visible, el recibo, el menú ⋮ (con TODAS) y el detalle ══ */}
        <div className="ml-auto flex max-w-full flex-wrap items-center justify-end gap-1.5 sm:self-center">
          {accionPrincipal && IconoAccionPrincipal && (
            <Button variant="secondary" size="sm" onClick={accionPrincipal.onClick}>
              <IconoAccionPrincipal className="h-4 w-4" aria-hidden="true" />
              {accionPrincipal.label}
            </Button>
          )}
          {pedido.estado_pago === 'pagado' && (
            <ReciboDropdown pedido={pedido} rol={perfil?.rol} />
          )}
          <AccionesDropdown pedido={pedido} {...contextoAcciones} {...handlersAcciones} />
          <Button
            variant="ghost"
            size="iconSm"
            onClick={() => setExpandido(!expandido)}
            aria-expanded={expandido}
            aria-controls={idDetalle}
            aria-label={expandido ? 'Ocultar detalle del pedido' : 'Ver detalle del pedido'}
            title={expandido ? 'Ocultar detalle' : 'Ver detalle'}
          >
            <ChevronDown
              className={`h-5 w-5 transition-transform duration-200 ${expandido ? 'rotate-180' : ''}`}
              aria-hidden="true"
            />
          </Button>
        </div>
      </div>

      {/* Contenido expandido del pedido */}
      {expandido && (
        <div id={idDetalle} className="px-4 pt-3 pb-4 border-t border-gray-200 dark:border-gray-700 space-y-3 animate-fade-in">
          {/* Carga: lo que antes iba en la línea de arriba de la tarjeta */}
          <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
            <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
              <Calendar className="w-4 h-4" aria-hidden="true" />
              Carga del pedido
            </h4>
            <div className="flex flex-wrap items-center gap-x-3 gap-y-1.5 text-sm text-gray-600 dark:text-gray-400">
              <span className="inline-flex items-center gap-1 font-medium" title="Fecha de carga">
                <Calendar className="w-3.5 h-3.5" aria-hidden="true" />
                {fechaCreacionLabel}
              </span>
              {horaCreacion && (
                <span className="inline-flex items-center gap-1 font-medium" title="Hora de creación">
                  <Clock className="w-3.5 h-3.5" aria-hidden="true" />
                  {horaCreacion}
                </span>
              )}
              <BadgeAntiguedad dias={diasAntiguedad} estado={pedido.estado} />
              {puedeVerGps && <BadgeGeolocalizacion pedido={pedido} />}
            </div>
          </div>

          {/* Informacion del cliente */}
          <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
            <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
              <User className="w-4 h-4" aria-hidden="true" />
              Informacion del Cliente
            </h4>
            <div className="space-y-1 text-sm">
              <p className="font-medium text-gray-900 dark:text-white">{pedido.cliente?.nombre_fantasia}</p>
              {pedido.cliente?.razon_social && (
                <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                  <Building2 className="w-3 h-3" aria-hidden="true" />
                  {pedido.cliente.razon_social}
                </p>
              )}
              {pedido.cliente?.cuit && (
                <p className="text-gray-500 dark:text-gray-400 text-xs font-mono">CUIT: {pedido.cliente.cuit}</p>
              )}
              <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                <MapPin className="w-3 h-3" aria-hidden="true" />
                {pedido.cliente?.direccion}
              </p>
              {pedido.cliente?.telefono && (
                <p className="text-gray-600 dark:text-gray-400 flex items-center gap-1">
                  <Phone className="w-3 h-3" aria-hidden="true" />
                  <a href={`tel:${pedido.cliente.telefono}`} className="text-blue-600 dark:text-blue-400 hover:underline">
                    {pedido.cliente.telefono}
                  </a>
                  {pedido.cliente?.contacto && <span className="text-gray-400 dark:text-gray-500">({pedido.cliente.contacto})</span>}
                </p>
              )}
            </div>
          </div>

          {/* Lista detallada de productos */}
          <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
            <h4 className="text-sm font-semibold text-gray-700 dark:text-gray-300 mb-2 flex items-center gap-2">
              <Package className="w-4 h-4" aria-hidden="true" />
              Productos ({pedido.items?.length || 0})
            </h4>
            <div className="space-y-2">
              {pedido.items?.map(item => {
                const salvedadItem = pedido.salvedades?.find(s => String(s.producto_id) === String(item.producto_id));
                const cantidadOriginal = salvedadItem ? item.cantidad + salvedadItem.cantidad_afectada : item.cantidad;
                // Item con sustitucion de regalo: la marca queda como
                // "[Sustituido por: X]" en descripcion_regalo (lo agrega
                // sustituir_regalo_pedido y el trigger pre-insert). Para la
                // tarjeta queremos mostrar el nombre actual del producto +
                // un badge "Sustituido" pequeno + tooltip con la descripcion.
                const esSustituido = Boolean(
                  item.es_bonificacion
                  && item.descripcion_regalo
                  && item.descripcion_regalo.includes('[Sustituido por:')
                );
                return (
                <div key={item.id} className={`flex justify-between items-center py-2 border-b dark:border-gray-600 last:border-0 ${salvedadItem ? 'border-l-2 border-l-amber-400 dark:border-l-amber-500 pl-2 -ml-1' : ''} ${item.es_bonificacion ? 'bg-green-50 dark:bg-green-900/20 rounded px-2 -mx-1' : ''}`}>
                  <div className="flex-1">
                    <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1.5 flex-wrap">
                      {item.es_bonificacion && <Gift className="w-4 h-4 text-green-600 dark:text-green-400 flex-shrink-0" aria-hidden="true" />}
                      {item.es_bonificacion
                        ? (esSustituido
                            ? (item.producto?.nombre || 'Regalo sustituido')
                            : (item.descripcion_regalo || item.producto?.nombre || 'Regalo'))
                        : (item.producto?.nombre || 'Producto')}
                      {item.es_bonificacion && <span className="text-xs bg-green-100 dark:bg-green-800 text-green-700 dark:text-green-300 px-1.5 py-0.5 rounded-full font-medium">REGALO</span>}
                      {esSustituido && (
                        <span
                          className="inline-flex items-center gap-1 text-xs bg-orange-100 dark:bg-orange-900/40 text-orange-700 dark:text-orange-300 px-1.5 py-0.5 rounded-full font-medium"
                          title={item.descripcion_regalo || ''}
                        >
                          <RefreshCw className="w-3 h-3" aria-hidden="true" />
                          Sustituido
                        </span>
                      )}
                      {salvedadItem && (
                        <span className="text-xs bg-amber-100 dark:bg-amber-900/40 text-amber-700 dark:text-amber-300 px-1.5 py-0.5 rounded-full font-medium">
                          {MOTIVOS_SALVEDAD_LABELS[salvedadItem.motivo as MotivoSalvedad] || salvedadItem.motivo}
                        </span>
                      )}
                    </p>
                    {verPreciosLinea && !item.es_bonificacion && <p className="text-xs text-gray-500 dark:text-gray-400">{formatPrecio(item.precio_unitario)} c/u</p>}
                    {salvedadItem && (
                      <p className="text-xs text-amber-600 dark:text-amber-400">
                        Pedido: {cantidadOriginal} → Entregado: {item.cantidad} ({salvedadItem.cantidad_afectada} no entregadas)
                      </p>
                    )}
                  </div>
                  <div className="text-right">
                    {/* El regalo de una promo Fracción viene en botellas, no en
                        fardos: sin la etiqueta, "x392" se lee como 392 fardos. */}
                    <p className="font-semibold text-gray-700 dark:text-gray-300">{formatCantidadItem(item)}</p>
                    {equivalenteEnUnidades(item) && (
                      <p className="text-xs text-gray-500 dark:text-gray-400">{equivalenteEnUnidades(item)}</p>
                    )}
                    {verPreciosLinea && !item.es_bonificacion && <p className="text-sm font-bold text-blue-600 dark:text-blue-400">{formatPrecio(item.subtotal || item.precio_unitario * item.cantidad)}</p>}
                    {item.es_bonificacion && <p className="text-sm font-bold text-green-600 dark:text-green-400">$0</p>}
                    {verPreciosLinea && salvedadItem && (
                      <p className="text-xs text-red-500 dark:text-red-400">-{formatPrecio(salvedadItem.monto_afectado)}</p>
                    )}
                  </div>
                </div>
                );
              })}
              <div className="flex justify-between items-center pt-2 border-t-2 dark:border-gray-600">
                <p className="font-bold text-gray-900 dark:text-white">Total</p>
                <p className="text-xl font-bold text-blue-600 dark:text-blue-400">{formatPrecio(pedido.total)}</p>
              </div>
            </div>
          </div>

          {/* Salvedades */}
          {tieneSalvedad && (
            <div className="p-3 bg-amber-50 dark:bg-amber-900/20 border border-amber-200 dark:border-amber-800 rounded-lg">
              <h4 className="text-sm font-semibold text-amber-700 dark:text-amber-300 mb-2 flex items-center gap-2">
                <AlertTriangle className="w-4 h-4" aria-hidden="true" />
                Salvedades ({pedido.salvedades?.length})
              </h4>
              <div className="space-y-2">
                {pedido.salvedades?.map(salvedad => {
                  // String() de los dos lados, como la fila del ítem: PostgREST manda
                  // `producto_id` numérico en los ítems y la salvedad ya viene en String.
                  const productoItem = pedido.items?.find(i => String(i.producto_id) === String(salvedad.producto_id));
                  const motivoLabel = MOTIVOS_SALVEDAD_LABELS[salvedad.motivo as MotivoSalvedad] || salvedad.motivo;
                  return (
                    <div key={salvedad.id} className="flex justify-between items-center py-2 border-b border-amber-200 dark:border-amber-700 last:border-0">
                      <div className="flex-1">
                        <p className="font-medium text-amber-900 dark:text-amber-100">
                          {productoItem?.producto?.nombre || 'Producto'}
                        </p>
                        <p className="text-xs text-amber-700 dark:text-amber-300">
                          {motivoLabel} - {salvedad.cantidad_afectada} unidad(es)
                        </p>
                        <span className={`inline-block mt-1 px-2 py-0.5 rounded-full text-xs ${
                          salvedad.estado_resolucion === 'pendiente'
                            ? 'bg-amber-200 text-amber-800 dark:bg-amber-800 dark:text-amber-200'
                            : 'bg-green-200 text-green-800 dark:bg-green-800 dark:text-green-200'
                        }`}>
                          {salvedad.estado_resolucion === 'pendiente' ? 'Pendiente de resolver' : 'Resuelta'}
                        </span>
                      </div>
                      {verPreciosLinea && (
                        <div className="text-right">
                          <p className="text-sm font-bold text-red-600 dark:text-red-400">
                            -{formatPrecio(salvedad.monto_afectado)}
                          </p>
                        </div>
                      )}
                    </div>
                  );
                })}
                {verPreciosLinea && (
                  <div className="flex justify-between items-center pt-2 border-t border-amber-300 dark:border-amber-600">
                    <p className="text-sm font-medium text-amber-800 dark:text-amber-200">Total afectado:</p>
                    <p className="text-sm font-bold text-red-600 dark:text-red-400">
                      -{formatPrecio(pedido.salvedades?.reduce((sum, s) => sum + s.monto_afectado, 0) || 0)}
                    </p>
                  </div>
                )}
              </div>
            </div>
          )}

          {/* Motivo de cancelacion */}
          {pedido.estado === 'cancelado' && pedido.motivo_cancelacion && (
            <div className="p-3 bg-red-50 dark:bg-red-900/20 border border-red-200 dark:border-red-800 rounded-lg">
              <h4 className="text-sm font-semibold text-red-700 dark:text-red-300 mb-1 flex items-center gap-2">
                <AlertTriangle className="w-4 h-4" aria-hidden="true" />
                Motivo de cancelacion
              </h4>
              <p className="text-sm text-red-800 dark:text-red-200 whitespace-pre-wrap">{pedido.motivo_cancelacion}</p>
            </div>
          )}

          {/* Notas */}
          {pedido.notas && (
            <div className="p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-800 rounded-lg">
              <h4 className="text-sm font-semibold text-yellow-700 dark:text-yellow-300 mb-1 flex items-center gap-2">
                <FileText className="w-4 h-4" aria-hidden="true" />
                Notas
              </h4>
              <p className="text-sm text-yellow-800 dark:text-yellow-200 whitespace-pre-wrap">{pedido.notas}</p>
            </div>
          )}

          {/* Info de pago y transporte */}
          <div className="grid grid-cols-2 gap-3">
            <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
              <p className="text-xs text-gray-500 dark:text-gray-400">{esVB ? 'Comprobante' : 'Forma de pago'}</p>
              <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1">
                <CreditCard className="w-4 h-4" aria-hidden="true" />
                {esVB ? 'Vale blanco — consumo interno' : getFormaPagoDisplay(pedido)}
              </p>
              {/* Desglose cuando el pago fue combinado: muestra cuanto se cobro
                  por cada forma sin abrir el modal de pagos. */}
              {!esVB && (() => {
                const pagos = pedido.pagos || [];
                const formas = Array.from(new Set(pagos.map(p => p.forma_pago).filter(Boolean)));
                if (formas.length < 2) return null;
                const desglose = formas.map(f => ({
                  forma: f,
                  monto: pagos.filter(p => p.forma_pago === f).reduce((s, p) => s + (p.monto || 0), 0),
                }));
                return (
                  <div className="mt-1.5 pt-1.5 border-t border-gray-200 dark:border-gray-600 space-y-0.5 text-xs text-gray-600 dark:text-gray-400">
                    {desglose.map(d => (
                      <div key={d.forma} className="flex justify-between">
                        <span>{getFormaPagoLabel(d.forma)}</span>
                        <span className="font-medium">{formatPrecio(d.monto)}</span>
                      </div>
                    ))}
                  </div>
                );
              })()}
            </div>
            <div className="p-3 bg-gray-50 dark:bg-gray-700/50 rounded-lg">
              <p className="text-xs text-gray-500 dark:text-gray-400">Transportista</p>
              <p className="font-medium text-gray-900 dark:text-white flex items-center gap-1">
                <Truck className="w-4 h-4" aria-hidden="true" />
                {pedido.transportista?.nombre || 'Sin asignar'}
              </p>
            </div>
          </div>
        </div>
      )}
    </Card>
  );
}

// Dropdown para elegir formato de recibo
function ReciboDropdown({ pedido, rol }: { pedido: PedidoDB; rol?: RolUsuario | null }) {
  const [open, setOpen] = React.useState(false);
  const ref = React.useRef<HTMLDivElement>(null);
  const notify = useNotification();

  React.useEffect(() => {
    function handleClickOutside(e: MouseEvent) {
      if (ref.current && !ref.current.contains(e.target as Node)) setOpen(false);
    }
    if (open) document.addEventListener('mousedown', handleClickOutside);
    return () => document.removeEventListener('mousedown', handleClickOutside);
  }, [open]);

  const handleExport = async (formato: 'a4' | 'comanda') => {
    setOpen(false);
    if (pedido.cliente) {
      await generarReciboPedido(pedido, pedido.cliente, { formato, rol });
    } else {
      notify.error('No se puede generar el recibo: el pedido no tiene cliente cargado.');
    }
  };

  return (
    <div className="relative" ref={ref}>
      <button
        onClick={() => setOpen(!open)}
        className="flex items-center gap-1 px-3 py-1.5 text-sm bg-green-50 dark:bg-green-900/30 text-green-600 dark:text-green-400 rounded-lg hover:bg-green-100 dark:hover:bg-green-900/50 transition-colors"
        title="Descargar recibo PDF"
      >
        <FileDown className="w-4 h-4" />
        <span className="hidden sm:inline">Recibo</span>
        <ChevronDown className="w-3 h-3" />
      </button>
      {/* Abre hacia abajo: el botón ahora está arriba de la tarjeta, y hacia
          arriba se metía sobre la tarjeta anterior o el encabezado de la lista. */}
      {open && (
        <div className="absolute right-0 top-full mt-1 w-44 bg-white dark:bg-gray-800 rounded-lg shadow-lg border dark:border-gray-700 z-50 overflow-hidden">
          <button
            onClick={() => handleExport('a4')}
            className="w-full px-3 py-2.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white border-b dark:border-gray-700"
          >
            <p className="font-medium">Hoja A4</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Formato profesional</p>
          </button>
          <button
            onClick={() => handleExport('comanda')}
            className="w-full px-3 py-2.5 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-700 dark:text-white"
          >
            <p className="font-medium">Comanda</p>
            <p className="text-xs text-gray-500 dark:text-gray-400">Ticket 75mm</p>
          </button>
        </div>
      )}
    </div>
  );
}

export default memo(PedidoCard);
