import { useState, useMemo, memo, useRef, useEffect } from 'react';
import { X, Loader2, Search, MapPin, Tag, Calendar, Trash2, Pencil, Gift, Truck, ChevronLeft, ChevronRight, ShoppingCart, ChevronUp, LocateFixed, AlertCircle, UserCheck, Percent, Plus } from 'lucide-react';
import { formatPrecio, fechaLocalISO, formatFecha } from '../../utils/formatters';
import { parsePrecio } from '../../utils/calculations';
import { AddressAutocomplete } from '../AddressAutocomplete';
import { usePromocionPedido, type RegaloOverride } from '../../hooks/usePromocionPedido';
import { resolverDescuentoPctCliente } from '../../utils/descuentoCliente';
import { validarRepartoRegalo, type ParteReparto } from '../../utils/repartoRegalo';
import type { BonificacionResult } from '../../utils/promociones';
import { useGeolocationCapture } from '../../hooks/useGeolocationCapture';
import { usePreventistasAsignablesQuery } from '../../hooks/queries/useUsuariosQuery';
import ModalBase from './ModalBase';
import BottomSheet from '../ui/BottomSheet';
import { CompactErrorBoundary } from '../ErrorBoundary';
import { useMediaQuery, CONSULTA_CELULAR } from '../../hooks/state/useMediaQuery';
import ModalConfirmacion, { type ModalConfirmacionConfig } from './ModalConfirmacion';
import { Button } from '../ui/Button';
import { obtenerMOQ } from '../../utils/precioMayorista';
import { motivoMontoMinimo } from '../../utils/montoMinimo';
import { avisoDeudaCliente } from '../../utils/deudaCliente';
import { usePoliticasComercialesQuery } from '../../hooks/queries/usePoliticasComercialesQuery';
import { esProductoMostrable, filtrarProductosOperativos } from '../../utils/productosOperativos';
import { filtrarRegalosCompatibles, TEXTO_REGALO_MISMA_CATEGORIA } from '../../utils/regaloCompatible';
import GeolocationGate from '../GeolocationGate';
import NumberInput from '../ui/NumberInput';
import { Combobox } from '../ui/Combobox';
import FranjasHorariasEditor from '../ui/FranjasHorariasEditor';
import DiasAtencionSelector from '../ui/DiasAtencionSelector';
import BloqueHorarioRequerido, { type PatchHorarioCliente } from '../ui/BloqueHorarioRequerido';
import { serializarFranjas, validarFranjas, clienteSinHorario } from '../../utils/horariosCliente';
import type { FranjaHoraria } from '../../utils/horariosCliente';
import { mensajeDuplicado, cambiaIdentidadDuplicado, type MensajeDuplicado, type VeredictoDuplicadoRPC } from '../../utils/duplicadoCliente';
import type { ProductoDB, ClienteDB } from '../../types';

// Alto del alta en el sheet. Un navegador sin `dvh` (Chrome < 108, Safari <
// 15.4) descarta el valor inline entero y el sheet crecería más que la pantalla,
// con la X y Confirmar fuera de alcance: ahí va en `vh`.
const ALTO_SHEET =
  typeof CSS !== 'undefined' && typeof CSS.supports === 'function' && CSS.supports('height', '1dvh')
    ? '92dvh'
    : '92vh';

/** Item en el pedido */
export interface PedidoItem {
  productoId: string;
  cantidad: number;
  precioUnitario: number;
  precioOverride?: boolean;
}

/** Estado del nuevo pedido */
export interface NuevoPedidoState {
  clienteId: string;
  items: PedidoItem[];
  notas: string;
  formaPago?: string;
  estadoPago?: string;
  montoPagado?: number;
  fecha?: string;
  tipoFactura?: 'ZZ' | 'FC';
  fechaEntregaProgramada?: string;
  // Preventista al que se asigna el pedido. Solo admin lo modifica.
  // Si queda undefined, el RPC asigna al actor (auth.uid()).
  preventistaId?: string;
}

/** Datos del cliente a crear */
export interface NuevoClienteData {
  nombre: string;
  nombreFantasia: string;
  direccion: string;
  telefono: string;
  zona: string;
  razonSocial?: string; // Se usa "nombre" como razonSocial en creación rápida
  latitud?: number | null;
  longitud?: number | null;
  // Horarios de atención serializados ("HH:MM-HH:MM y …"); vacío si no se cargan.
  horariosAtencion?: string;
  /** Días que abre, bitmask Lunes→Domingo (mig 140). */
  dias_atencion?: string | null;
}

/** Advertencia de stock */
export interface StockWarning {
  tipo: 'error' | 'warning';
  mensaje: string;
}

/** Categoria option type - can be string or object */
export type CategoriaOption = string | { id: string; nombre: string; descripcion?: string };

 
/** Props del componente ModalPedido */
export interface ModalPedidoProps {
  /** Lista de productos disponibles */
  productos: ProductoDB[];
  /** Lista de clientes */
  clientes: ClienteDB[];
  /** Categorías disponibles */
  categorias: string[] | CategoriaOption[];
  /** Estado del nuevo pedido */
  nuevoPedido: NuevoPedidoState;
  /** Callback al cerrar */
  onClose: () => void;
  /** Callback al cambiar cliente */
  onClienteChange: (clienteId: string) => void;
  /** Callback al agregar item */
  onAgregarItem: (productoId: string, cantidad?: number, precio?: number) => void;
  /** Callback al actualizar cantidad */
  onActualizarCantidad: (productoId: string, cantidad: number) => void;
  /** Callback al crear cliente */
  onCrearCliente: (cliente: Record<string, unknown>) => Promise<{ id: string | number }>;
  /**
   * Guard de duplicados (mig 250) para el alta rápida. Se llama ANTES de
   * `onCrearCliente`, igual que `onVerificarDuplicado` en `ModalCliente`, para
   * poder mostrar la confirmación acá adentro en vez de depender del texto del
   * error que tira `createCliente` como última línea de defensa. Opcional:
   * sin esto, un aviso de duplicado no confirmable deja al alta rápida sin
   * forma de reintentar (ver #692).
   */
  onVerificarDuplicado?: (data: {
    direccion: string | null;
    latitud: number | null;
    longitud: number | null;
  }) => Promise<VeredictoDuplicadoRPC>;
  /** Callback al guardar pedido */
  onGuardar: () => void | Promise<void>;
  /** Indica si está guardando */
  guardando: boolean;
  /** Si es admin */
  isAdmin?: boolean;
  /** Si es preventista */
  isPreventista?: boolean;
  /** Si es encargado */
  isEncargado?: boolean;
  /** Callback al cambiar notas */
  onNotasChange?: (notas: string) => void;
  /** Callback al cambiar forma de pago */
  onFormaPagoChange?: (formaPago: string) => void;
  /** Callback al cambiar estado de pago */
  onEstadoPagoChange?: (estadoPago: string) => void;
  /** Callback al cambiar monto pagado */
  onMontoPagadoChange?: (monto: number) => void;
  /** Callback al cambiar fecha del pedido */
  onFechaChange?: (fecha: string) => void;
  /** Callback al cambiar tipo de factura */
  onTipoFacturaChange?: (tipo: 'ZZ' | 'FC') => void;
  /** Callback al cambiar fecha de entrega programada */
  onFechaEntregaProgramadaChange?: (fecha: string) => void;
  /** Callback al actualizar precio (solo admin) */
  onActualizarPrecio?: (productoId: string, precio: number) => void;
  /** Si está offline */
  isOffline?: boolean;
  /**
   * Si el rol puede ver el aviso de deuda previa del cliente. Lo decide el
   * container con `puedeVerDeudaCliente` (src/lib/permisos.ts) para no evaluar
   * el criterio de permisos acá adentro.
   */
  puedeVerDeuda?: boolean;
  /**
   * Timestamp del fetch de clientes (`dataUpdatedAt`). Solo se usa sin conexión,
   * para fechar el saldo en el aviso de deuda.
   */
  saldoActualizadoAt?: number | null;
  /** Callback al cambiar el preventista asignado (solo admin) */
  onPreventistaChange?: (preventistaId: string) => void;
  /** ID del usuario actual (default del selector de preventista) */
  currentUserId?: string;
  /** Override del regalo por promoId (admin lo elige al crear): una parte o un reparto en sabores. */
  regalosOverride?: Record<string, RegaloOverride>;
  /**
   * Callback cuando el admin cambia el regalo de una promo al crear. Manda las
   * partes completas de la promo (una = cambiar el producto; dos o más =
   * repartirlo en sabores), también mientras el reparto todavía no cierra.
   */
  onCambiarRegaloCreacion?: (promoId: string, partes: ParteReparto[]) => void;
  /** Promos quitadas a mano del pedido (para mostrar la fila "quitada" + restaurar). */
  promosEliminadas?: Array<{ promoId: string; promoNombre: string }>;
  /** Callback al quitar una promo del pedido (abre la confirmación en el container). */
  onEliminarPromoCreacion?: (promoId: string, promoNombre: string) => void;
  /** Callback al restaurar una promo previamente quitada. */
  onRestaurarPromoCreacion?: (promoId: string) => void;
  /**
   * Persiste el horario del cliente seleccionado sin salir del modal (mig 157).
   * Si no se provee, el pedido de horario no bloquea (útil para tests y para
   * cualquier consumidor que no pueda escribir clientes).
   */
  onGuardarHorarioCliente?: (clienteId: string, patch: PatchHorarioCliente) => Promise<void>;
}
 

/** Las bonificaciones de una promo, juntas (un reparto en sabores son varias). */
interface GrupoBonificacion {
  key: string;
  promoId?: string;
  promoNombre: string;
  lineas: BonificacionResult[];
  total: number;
  productoDefaultId: string;
}

const ModalPedido = memo(function ModalPedido({
  productos,
  clientes,
  categorias,
  nuevoPedido,
  onClose,
  onClienteChange,
  onAgregarItem,
  onActualizarCantidad,
  onCrearCliente,
  onVerificarDuplicado,
  onGuardar,
  guardando,
  isAdmin,
  isPreventista,
  isEncargado,
  onNotasChange,
  onFormaPagoChange,
  onEstadoPagoChange,
  onMontoPagadoChange,
  onFechaChange,
  onTipoFacturaChange,
  onFechaEntregaProgramadaChange,
  onActualizarPrecio,
  onPreventistaChange,
  currentUserId,
  isOffline,
  puedeVerDeuda,
  saldoActualizadoAt,
  regalosOverride,
  onCambiarRegaloCreacion,
  promosEliminadas,
  onEliminarPromoCreacion,
  onRestaurarPromoCreacion,
  onGuardarHorarioCliente
}: ModalPedidoProps) {
  // Solo admin puede reasignar preventista al pedido. La query se habilita
  // condicionalmente para no traer perfiles para preventistas/encargados.
  const { data: preventistasAsignables = [] } = usePreventistasAsignablesQuery();
  // Atribución explícita: el admin DEBE elegir quién vende (sin default silencioso
  // a su propio nombre, que cargaba ventas de preventistas al admin). El usuario_id
  // del pedido = el vendedor elegido; creado_por (quién carga) se setea server-side.
  const preventistaSeleccionado = nuevoPedido.preventistaId ?? '';
  const debeElegirPreventista =
    isAdmin && preventistasAsignables.length > 0 && !preventistaSeleccionado;

  const [busquedaProducto, setBusquedaProducto] = useState<string>('');
  const [busquedaCliente, setBusquedaCliente] = useState<string>('');
  const categoriasScrollRef = useRef<HTMLDivElement>(null);
  const [editingPriceId, setEditingPriceId] = useState<string | null>(null);
  const [editingPriceValue, setEditingPriceValue] = useState<string>('');
  // Input de la edición de precio (a lo sumo uno a la vez): el listener de
  // Escape de abajo lo reconoce por acá.
  const precioInputRef = useRef<HTMLInputElement>(null);
  // La edición de precio ya se resolvió por teclado (Enter guardó, Escape
  // canceló). Chrome dispara `blur` al sacar del DOM el input con foco, y el
  // onBlur guarda: sin esta marca, Escape cancelaba y el blur guardaba igual lo
  // tipeado (y Enter guardaba dos veces). Se reinicia al empezar cada edición.
  const precioResueltoRef = useRef<boolean>(false);
  const [categoriaSeleccionada, setCategoriaSeleccionada] = useState<string>('');
  const [mostrarNuevoCliente, setMostrarNuevoCliente] = useState<boolean>(false);
  const [nuevoCliente, setNuevoCliente] = useState<NuevoClienteData>({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '', latitud: null, longitud: null });
  // Horarios de atención del alta rápida (mismo editor de franjas que "Editar cliente").
  const [franjasAtencion, setFranjasAtencion] = useState<FranjaHoraria[]>([{ apertura: '', cierre: '' }]);
  // Días que abre (bitmask L→D). El ruteo lo usa para no visitar un local cerrado.
  const [diasAtencion, setDiasAtencion] = useState<string | null>(null);
  const [guardandoCliente, setGuardandoCliente] = useState<boolean>(false);
  const [errorCliente, setErrorCliente] = useState<string>('');
  // Aviso de duplicado (mig 250) del alta rápida pendiente de confirmar. Guarda
  // la identidad (dirección/coords) verificada para poder invalidarse sola si
  // el usuario la sigue editando: confirmar sobre datos que ya cambiaron
  // confirmaría el lugar equivocado.
  const [duplicadoPendiente, setDuplicadoPendiente] = useState<{
    mensaje: MensajeDuplicado;
    identidad: { direccion: string | null; latitud: number | null; longitud: number | null };
  } | null>(null);
  const [carritoAbierto, setCarritoAbierto] = useState<boolean>(false);

  // Escape en la edición de precio cancela SÓLO la edición, no el alta (#853).
  // El cancelar lo hace el onKeyDown del input; esto evita que además cierre el
  // diálogo. `stopPropagation` ahí no alcanza: Radix escucha Escape en
  // `document` en fase de CAPTURA, así que corre antes que cualquier handler del
  // input (React cuelga los suyos de la raíz). Un listener de captura en
  // `window` va antes que el de `document` y marca el evento como
  // `defaultPrevented`, que es lo que Radix mira para no cerrar. Sirve igual
  // para ModalBase y para BottomSheet (que no expone `onEscapeKeyDown`). Sólo
  // actúa con el foco en el input de precio: con la edición cerrada, Escape
  // vuelve a cerrar el alta como siempre.
  useEffect(() => {
    if (editingPriceId === null) return;
    precioResueltoRef.current = false;
    const noCerrarElAlta = (e: KeyboardEvent) => {
      if (e.key === 'Escape' && e.target === precioInputRef.current) e.preventDefault();
    };
    window.addEventListener('keydown', noCerrarElAlta, true);
    return () => window.removeEventListener('keydown', noCerrarElAlta, true);
  }, [editingPriceId]);

  // Escape con la lista de un combobox abierta (el selector de regalo) cierra la
  // LISTA, no el alta. Mismo mecanismo que arriba: listener de captura que marca
  // el evento como `defaultPrevented` antes de que Radix lo mire.
  useEffect(() => {
    const noCerrarElAlta = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return;
      const t = e.target as HTMLElement | null;
      if (t?.getAttribute?.('role') === 'combobox' && t.getAttribute('aria-expanded') === 'true') e.preventDefault();
    };
    window.addEventListener('keydown', noCerrarElAlta, true);
    return () => window.removeEventListener('keydown', noCerrarElAlta, true);
  }, []);

  // Celular (debajo de 640 px, el corte `sm:`): bottom sheet. Escritorio:
  // ModalBase, como siempre. Se decide UNA vez, al abrir, y queda fijo hasta
  // cerrar: si la ventana cruza el corte con el alta abierta (girar el
  // teléfono, achicar la ventana) se queda el envoltorio con el que abrió.
  // Cambiarlo remontaría el cuerpo entero, y aunque el pedido vive en el
  // container y los campos de acá en este componente, adentro hay estado que no
  // es de nadie más: el permiso de GPS de `GeolocationGate` (volvería a pedirlo,
  // y un "Continuar sin GPS" se perdería), el horario a medio cargar de
  // `BloqueHorarioRequerido`, el scroll y el foco. Los dos envoltorios andan en
  // cualquier ancho; lo que se elige al abrir es el que mejor queda.
  const esCelular = useMediaQuery(CONSULTA_CELULAR);
  const [enSheet] = useState<boolean>(esCelular);

  // GPS capture para cliente rapido. `gpsAccuracy` sirve como flag: si esta
  // seteado, las coords vinieron del GPS (mostramos badge + precision); si es
  // null pero hay lat/lng, vinieron del autocomplete.
  const capturarGps = useGeolocationCapture();
  const [gpsCapturando, setGpsCapturando] = useState<boolean>(false);
  const [gpsError, setGpsError] = useState<string | null>(null);
  const [gpsAccuracy, setGpsAccuracy] = useState<number | null>(null);

  // El producto agotado SÍ se lista (deshabilitado y con el motivo), igual que
  // el producto sin precio. Antes se filtraba por `p.stock > 0` y desaparecía
  // del buscador: el vendedor no podía distinguir "no existe" de "lo escribí
  // mal" de "está agotado", con el cliente esperando.
  //
  // Los desactivados nunca se listan; el agotado se lista sólo si la política
  // `mostrarSinStock` está prendida (src/utils/productosOperativos.ts).
  const { politicas } = usePoliticasComercialesQuery();
  const mostrarSinStock = politicas.mostrarSinStock;
  const productosFiltrados = useMemo(() => {
    return productos.filter(p => {
      if (!esProductoMostrable(p, { mostrarSinStock })) return false;
      const matchNombre = p.nombre.toLowerCase().includes(busquedaProducto.toLowerCase());
      const matchCategoria = !categoriaSeleccionada || p.categoria === categoriaSeleccionada;
      return matchNombre && matchCategoria;
    });
  }, [productos, busquedaProducto, categoriaSeleccionada, mostrarSinStock]);

  // Opciones para el selector de regalo (admin): los productos operativos, ordenados.
  const productosRegaloOpciones = useMemo(
    () => filtrarProductosOperativos(productos).sort((a, b) => (a.nombre || '').localeCompare(b.nombre || '')),
    [productos]
  );

  const getKeyProductoRegalo = (p: ProductoDB) => String(p.id);
  const getLabelProductoRegalo = (p: ProductoDB) => p.nombre;
  const renderOpcionProductoRegalo = (p: ProductoDB) => (
    <>
      {p.nombre}
      {p.activo === false ? ' · desactivado' : ((p.stock ?? 0) > 0 ? '' : ' · sin stock')}
    </>
  );

  const clientesFiltrados = useMemo(() => {
    if (busquedaCliente.length < 2) return [];
    // Normalizar: trim, colapsar espacios, reemplazar non-breaking spaces
    const busquedaNorm = busquedaCliente.replace(/[\s\u00A0]+/g, ' ').trim().toLowerCase();
    if (!busquedaNorm) return [];
    return clientes.filter(c => {
      const norm = (s: string | null | undefined) => s?.replace(/[\s\u00A0]+/g, ' ').trim().toLowerCase() ?? '';
      return norm(c.nombre_fantasia).includes(busquedaNorm) ||
        norm(c.razon_social).includes(busquedaNorm) ||
        norm(c.direccion).includes(busquedaNorm) ||
        c.cuit?.includes(busquedaCliente.replace(/[-\s]/g, '')) ||
        (c.codigo != null && String(c.codigo).includes(busquedaCliente.trim()));
    }).slice(0, 8);
  }, [clientes, busquedaCliente]);

  const clienteSeleccionado = useMemo(() => {
    if (!nuevoPedido.clienteId) return null;
    // clienteId is a string, compare directly with string id
    return clientes.find(c => String(c.id) === String(nuevoPedido.clienteId)) || null;
  }, [clientes, nuevoPedido.clienteId]);

  // Horario obligatorio (mig 157): si el cliente elegido no tiene un horario
  // utilizable, se pide acá mismo y no se puede confirmar el pedido hasta
  // resolverlo. Antes había que salir del pedido, editar el cliente y volver —
  // con el cliente esperando, nadie lo hacía y el ruteo quedaba sin ventanas.
  const faltaHorarioCliente =
    !!onGuardarHorarioCliente && clienteSinHorario(clienteSeleccionado);

  // Deuda previa del cliente elegido. AVISA, NO BLOQUEA: es una decisión
  // explícita: quien vende decide si igual le carga el pedido. Por eso no toca
  // `disabled` del botón Confirmar, a diferencia del mínimo de compra.
  // Acá el saldo no incluye este pedido —todavía no existe—, así que se usa
  // crudo; en la tarjeta hay que descontarlo (ver src/utils/deudaCliente.ts).
  const avisoDeuda = puedeVerDeuda
    ? avisoDeudaCliente(clienteSeleccionado?.saldo_cuenta, {
        saldoAl: isOffline && saldoActualizadoAt ? formatFecha(new Date(saldoActualizadoAt)) : null,
      })
    : null;

  const handleCapturarGps = async (): Promise<void> => {
    setGpsCapturando(true);
    setGpsError(null);
    const result = await capturarGps();
    setGpsCapturando(false);
    if (result.status === 'ok') {
      setNuevoCliente(prev => ({ ...prev, latitud: result.lat, longitud: result.lng }));
      setGpsAccuracy(result.accuracy);
    } else {
      const msg =
        result.status === 'denied'      ? 'Permiso de ubicación denegado. Habilitalo en el navegador.' :
        result.status === 'timeout'     ? 'Se tardó demasiado. Probá moverte a un área con mejor señal.' :
        result.status === 'unavailable' ? 'GPS no disponible en este dispositivo.' :
                                          'No se pudo obtener la ubicación.';
      setGpsError(msg);
    }
  };

  // El aviso de duplicado se invalida solo si el usuario sigue tocando dónde
  // está el cliente: confirmar tiene que confirmar la MISMA dirección/punto
  // que se verificó, no una que cambió mientras el aviso estaba en pantalla.
  useEffect(() => {
    if (!duplicadoPendiente) return;
    const actual = {
      direccion: nuevoCliente.direccion ?? null,
      latitud: nuevoCliente.latitud ?? null,
      longitud: nuevoCliente.longitud ?? null,
    };
    if (cambiaIdentidadDuplicado(duplicadoPendiente.identidad, actual)) {
      setDuplicadoPendiente(null);
      setErrorCliente('');
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nuevoCliente.direccion, nuevoCliente.latitud, nuevoCliente.longitud]);

  const crearClienteRapido = async (duplicadoConfirmado: boolean): Promise<void> => {
    setGuardandoCliente(true);
    try {
      // Usar "nombre" como razonSocial (requerido por la DB)
      const clienteData = {
        ...nuevoCliente,
        razonSocial: nuevoCliente.nombre?.trim(), // El "Nombre completo" es la razón social
        horariosAtencion: serializarFranjas(franjasAtencion),
        dias_atencion: diasAtencion,
        duplicadoConfirmado,
      };
      const cliente = await onCrearCliente(clienteData);
      onClienteChange(cliente.id.toString());
      setMostrarNuevoCliente(false);
      setNuevoCliente({ nombre: '', nombreFantasia: '', direccion: '', telefono: '', zona: '', latitud: null, longitud: null });
      setFranjasAtencion([{ apertura: '', cierre: '' }]);
      setDiasAtencion(null);
      setGpsAccuracy(null);
      setGpsError(null);
      setErrorCliente('');
      setDuplicadoPendiente(null);
    } catch (err) {
      const errorMsg = err instanceof Error ? err.message : 'Error al crear cliente';
      setErrorCliente(errorMsg);
      setDuplicadoPendiente(null);
    }
    setGuardandoCliente(false);
  };

  const handleCrearClienteRapido = async (): Promise<void> => {
    const nombre = nuevoCliente.nombre?.trim();
    const nombreFantasia = nuevoCliente.nombreFantasia?.trim();
    const direccion = nuevoCliente.direccion?.trim();

    // Validación con feedback al usuario
    const camposFaltantes: string[] = [];
    if (!nombreFantasia) camposFaltantes.push('Nombre fantasía');
    if (!nombre) camposFaltantes.push('Nombre completo');
    if (!direccion) camposFaltantes.push('Dirección');
    if (camposFaltantes.length > 0) {
      setErrorCliente(`Completá: ${camposFaltantes.join(', ')}`);
      setDuplicadoPendiente(null);
      return;
    }
    // Las franjas son opcionales, pero si hay alguna cargada debe ser válida.
    if (!validarFranjas(franjasAtencion).valido) {
      setErrorCliente('Revisá los horarios de atención: la apertura debe ser anterior al cierre y las franjas no pueden superponerse.');
      setDuplicadoPendiente(null);
      return;
    }
    setErrorCliente('');
    setDuplicadoPendiente(null);

    // Guard de duplicados (mig 250). Se verifica ACÁ, antes de crear, para
    // poder ofrecer un botón de confirmación si sólo avisa: `createCliente`
    // vuelve a correr el mismo chequeo como última línea de defensa, así que
    // saltearlo acá no crearía nada igual si algo cambió entre medio.
    if (onVerificarDuplicado) {
      const identidad = {
        direccion: nuevoCliente.direccion ?? null,
        latitud: nuevoCliente.latitud ?? null,
        longitud: nuevoCliente.longitud ?? null,
      };
      let veredicto: VeredictoDuplicadoRPC;
      setGuardandoCliente(true);
      try {
        veredicto = await onVerificarDuplicado(identidad);
      } catch (err) {
        setGuardandoCliente(false);
        setErrorCliente(
          err instanceof Error
            ? err.message
            : 'No se pudo verificar si ya existe un cliente igual. No se guardó nada; probá de nuevo.'
        );
        return;
      }
      setGuardandoCliente(false);

      if (veredicto.bloquea) {
        setErrorCliente(mensajeDuplicado(veredicto).mensaje);
        return;
      }
      if (veredicto.avisa) {
        setErrorCliente(mensajeDuplicado(veredicto).mensaje);
        setDuplicadoPendiente({ mensaje: mensajeDuplicado(veredicto), identidad });
        return;
      }
    }

    await crearClienteRapido(false);
  };

  const handleConfirmarDuplicadoYCrear = async (): Promise<void> => {
    if (!duplicadoPendiente) return;
    await crearClienteRapido(true);
  };

  const getStockWarning = (productoId: string, cantidadEnPedido: number): StockWarning | null => {
    const producto = productos.find(p => p.id === productoId);
    if (!producto) return null;
    // Bonificaciones NO descuentan stock — solo items comprados
    const stockDisponible = producto.stock - cantidadEnPedido;
    const stockMinimo = producto.stock_minimo || 10;
    if (stockDisponible < 0) return { tipo: 'error', mensaje: `Sin stock! Disponible: ${producto.stock}` };
    if (stockDisponible < stockMinimo) return { tipo: 'warning', mensaje: `Stock bajo: quedaran ${stockDisponible}` };
    return null;
  };

  // Faltantes de stock del carrito. Es la misma cuenta que `getStockWarning` ya
  // mostraba en rojo, pero ahora además BLOQUEA el confirmar: antes el cartel
  // era decorativo, el vendedor apretaba igual y el rechazo llegaba del servidor
  // con el cliente delante y el carrito entero cargado. El mínimo de venta ya se
  // comportaba así; el stock no, y eso enseñaba que "el rojo no importa".
  const violacionesStock = useMemo(() => {
    return nuevoPedido.items
      .map(item => {
        const producto = productos.find(p => p.id === item.productoId);
        if (!producto) return null;
        const disponible = Number(producto.stock) || 0;
        if (item.cantidad <= disponible) return null;
        return { productoId: item.productoId, nombre: producto.nombre, solicitado: item.cantidad, disponible };
      })
      .filter((v): v is { productoId: string; nombre: string; solicitado: number; disponible: number } => v !== null);
  }, [nuevoPedido.items, productos]);

  const calcularTotal = (): number => nuevoPedido.items.reduce((t, i) => t + (i.precioUnitario * i.cantidad), 0);

  // Confirmación de quitar promo: vive DENTRO del modal (no en el container),
  // porque ModalBase es un Radix Dialog modal y una confirmación renderizada
  // afuera queda detrás del overlay y es inalcanzable → la quita fallaba en
  // silencio. Mismo patrón que ModalEditarPedido.
  const [confirmConfig, setConfirmConfig] = useState<ModalConfirmacionConfig | null>(null);

  // Promos quitadas a mano → se excluyen de la resolución (display y submit).
  const promosEliminadasSet = useMemo(
    () => new Set((promosEliminadas ?? []).map(p => p.promoId)),
    [promosEliminadas],
  );

  // Precios mayoristas, promociones y cantidades mínimas
  // Las tres capas de precio (promo → mayorista → descuento del cliente) las
  // resuelve `orquestarPrecios` adentro del hook, con la misma función que usa
  // el bot de Telegram: así el total que ve el preventista acá y el que ve por
  // Telegram para el mismo pedido son el mismo número.
  const { preciosResueltos, faltantes, faltantesBonificacion, promoResolucion, bonificacionesBase, promoMap, totalOriginal, moqMap, minimosProducto, violacionesMOQ, totalConDescuentoCliente, hayDescuentoTotal } = usePromocionPedido(
    nuevoPedido.items,
    undefined,
    regalosOverride,
    promosEliminadasSet,
    { cliente: clienteSeleccionado, productos },
  );

  // Bonificaciones agrupadas por promo: un regalo repartido en sabores llega
  // como N líneas de la misma promo y se muestra en un solo bloque. `total` es
  // la bonificación que da la promo (la que tiene que sumar el reparto) y
  // `productoDefaultId`, el regalo que la promo da sin override.
  const gruposBonif = useMemo(() => {
    const grupos: GrupoBonificacion[] = [];
    const porPromo = new Map<string, GrupoBonificacion>();
    for (const b of promoResolucion.bonificaciones) {
      const promoId = b.promoId ? String(b.promoId) : undefined;
      let grupo = promoId ? porPromo.get(promoId) : undefined;
      if (!grupo) {
        const base = promoId ? bonificacionesBase?.find(x => String(x.promoId) === promoId) : undefined;
        grupo = {
          key: promoId ? `bonif-promo-${promoId}` : `bonif-prod-${b.productoId}`,
          promoId,
          promoNombre: b.promoNombre,
          lineas: [],
          // -1 = sin base: se completa abajo con la suma de las líneas.
          total: base ? base.cantidadBonificacion : -1,
          productoDefaultId: String(base?.productoId ?? b.productoId),
        };
        grupos.push(grupo);
        if (promoId) porPromo.set(promoId, grupo);
      }
      grupo.lineas.push(b);
    }
    // Sin base (el hook no la dio): el total es la suma de las líneas, que con
    // un reparto aplicado da la bonificación por construcción.
    for (const g of grupos) {
      if (g.total < 0) g.total = g.lineas.reduce((acc, l) => acc + l.cantidadBonificacion, 0);
    }
    return grupos;
  }, [promoResolucion.bonificaciones, bonificacionesBase]);

  // Las filas del regalo de una promo: el override que eligió el admin (con
  // los borradores incluidos) o, si no eligió nada, lo que da la promo.
  const partesDeGrupo = (grupo: GrupoBonificacion): ParteReparto[] => {
    const override = grupo.promoId ? regalosOverride?.[grupo.promoId] : undefined;
    if (override && override.partes.length > 0) {
      return override.partes.map(p => ({ productoId: String(p.productoId ?? ''), cantidad: Number(p.cantidad) || 0 }));
    }
    return grupo.lineas.map(l => ({ productoId: String(l.productoId), cantidad: l.cantidadBonificacion }));
  };

  // Productos que se pueden elegir como regalo de una promo (#950, solución
  // provisoria): los operativos de la MISMA categoría (y subcategoría, si el
  // regalo original la tiene) que el `producto_regalo_id` de la promo. El
  // contenedor de la promo descuenta con el factor del empaque del regalo
  // original (fardo x6 de Manaos 3L): un sustituto de otra presentación (500cc
  // x12, papas) descontaría mal el stock. Sin la promo en el mapa, el original
  // es el regalo que da hoy (`productoDefaultId`).
  const opcionesRegaloDePromo = (grupo: GrupoBonificacion): ProductoDB[] => {
    let originalId = grupo.productoDefaultId;
    if (promoMap && grupo.promoId) {
      for (const promos of promoMap.values()) {
        const promo = promos.find(pr => String(pr.id) === grupo.promoId);
        if (promo?.productoRegaloId) { originalId = String(promo.productoRegaloId); break; }
      }
    }
    const original = productos.find(p => String(p.id) === String(originalId));
    if (!original) return productosRegaloOpciones.filter(p => String(p.id) === String(grupo.productoDefaultId));
    return filtrarRegalosCompatibles(original, productosRegaloOpciones);
  };

  // Repartos del regalo que no cierran (suma distinta de la bonificación, fila
  // sin producto, cantidad no entera, sabor repetido): bloquean el confirmar.
  // `orquestarPrecios` no aplica un reparto así y mandaría el regalo default.
  const repartosRegaloInvalidos = gruposBonif.flatMap(grupo => {
    if (!isAdmin || !onCambiarRegaloCreacion || !grupo.promoId) return [];
    const partes = partesDeGrupo(grupo);
    if (partes.length < 2) return [];
    const v = validarRepartoRegalo(partes, grupo.total, grupo.productoDefaultId);
    return v.ok ? [] : [{ promoNombre: grupo.promoNombre, errores: v.errores }];
  });

  const totalItemsCarrito = nuevoPedido.items.reduce((t, i) => t + i.cantidad, 0);
  const totalParaMostrar = hayDescuentoTotal ? totalConDescuentoCliente : calcularTotal();
  const hayItems = nuevoPedido.items.length > 0;

  // Compra mínima de la sucursal (migs 204/205). La base la rechaza igual, pero
  // el rechazo del servidor llega con el cliente adelante y el carrito entero
  // cargado — y si el pedido se cargó sin señal, llega horas después. Se bloquea
  // acá por lo mismo que se bloquea el MOQ, y sobre el total que realmente se
  // persiste (el que ya tiene descuentos y promos aplicados).
  const motivoMinimo = hayItems
    ? motivoMontoMinimo(totalParaMostrar, politicas.montoMinimoPedido)
    : null;

  const tipoFacturaToggle = (
    <label className="flex items-center gap-1.5">
      <span className="text-xs font-medium text-gray-600 dark:text-gray-400">Factura</span>
      <select
        value={nuevoPedido.tipoFactura || 'ZZ'}
        onChange={(e) => onTipoFacturaChange?.(e.target.value as 'ZZ' | 'FC')}
        className="px-2 py-1 text-sm font-medium border rounded bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white"
        aria-label="Tipo de factura"
      >
        <option value="ZZ">ZZ</option>
        <option value="FC">FC</option>
      </select>
    </label>
  );

  // El cuerpo es UNO solo para los dos envoltorios (ver `enSheet`). Lo único
  // que cambia es cómo se reparte el alto: en escritorio el catálogo se topea
  // en 65vh dentro del max-h-[90vh] del diálogo, como siempre; en el sheet el
  // cuerpo es una columna que llena el alto fijo del sheet, el catálogo se
  // estira y la barra de Confirmar queda clavada abajo (footer sticky de
  // verdad, también con el teclado abierto: ver BottomSheet).
  const cuerpo = (
      <GeolocationGate enabled={!!isPreventista} onCancel={onClose}>
      <div className={enSheet ? 'relative overflow-hidden flex flex-1 min-h-0 flex-col' : 'relative overflow-hidden'}>
        <div className={enSheet ? 'flex-1 min-h-0 overflow-y-auto overscroll-contain p-4 space-y-4' : 'max-h-[65vh] overflow-y-auto overscroll-contain p-4 space-y-4'}>
          {/* Seccion Cliente */}
          <div>
            <div className="flex justify-between items-center mb-1">
              <label className="block text-sm font-medium dark:text-gray-200">Cliente *</label>
              {(isAdmin || isPreventista || isEncargado) && (
                <Button
                  variant="ghost"
                  size="sm"
                  onClick={() => { setMostrarNuevoCliente(!mostrarNuevoCliente); setErrorCliente(''); setDuplicadoPendiente(null); setGpsError(null); setGpsAccuracy(null); }}
                  className="text-blue-600 dark:text-blue-400"
                >
                  {mostrarNuevoCliente ? 'Cancelar' : '+ Nuevo'}
                </Button>
              )}
            </div>

            {mostrarNuevoCliente ? (
              <div className="border rounded-lg p-3 space-y-3 bg-blue-50 dark:bg-gray-700 dark:border-gray-600">
                <input type="text" value={nuevoCliente.nombreFantasia} onChange={e => setNuevoCliente(prev => ({ ...prev, nombreFantasia: e.target.value }))} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre fantasia *" />
                <input type="text" value={nuevoCliente.nombre} onChange={e => setNuevoCliente(prev => ({ ...prev, nombre: e.target.value }))} className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-800 dark:border-gray-600 dark:text-white" placeholder="Nombre completo *" />
                <AddressAutocomplete
                  value={nuevoCliente.direccion}
                  onChange={(val: string) => setNuevoCliente(prev => ({ ...prev, direccion: val }))}
                  onSelect={(result) => {
                    setNuevoCliente(prev => ({ ...prev, direccion: result.direccion, latitud: result.latitud, longitud: result.longitud }));
                    // Direccion elegida del autocomplete: las coords ya no son del GPS.
                    setGpsAccuracy(null);
                    setGpsError(null);
                  }}
                  placeholder="Buscar dirección... *"
                />
                {/* Boton "Usar mi ubicacion actual": complementa el autocomplete cuando
                    la direccion no se encuentra o devuelve coords de otra localidad.
                    Para preventistas, es el flujo mas comun (estan parados en el local). */}
                <div>
                  <Button
                    type="button"
                    onClick={handleCapturarGps}
                    disabled={gpsCapturando}
                    loading={gpsCapturando}
                    variant="ghost"
                    size="md"
                    className="w-full sm:w-auto border border-blue-200 dark:border-blue-800 bg-blue-50 dark:bg-blue-900/20 text-blue-700 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900/40"
                    aria-label="Usar mi ubicación actual para fijar las coordenadas del cliente"
                  >
                    {!gpsCapturando && <LocateFixed className="w-4 h-4" />}
                    {gpsCapturando ? 'Obteniendo ubicación…' : 'Usar mi ubicación actual'}
                  </Button>
                  <p className="text-xs text-gray-500 dark:text-gray-400 mt-1">
                    Útil si estás parado en el local del cliente.
                  </p>
                </div>

                {gpsError && (
                  <div className="flex items-start gap-2 text-xs text-red-600 dark:text-red-400 bg-red-50 dark:bg-red-900/20 px-3 py-2 rounded-lg">
                    <AlertCircle className="w-4 h-4 mt-0.5 shrink-0" />
                    <span>{gpsError}</span>
                  </div>
                )}

                {nuevoCliente.latitud != null && nuevoCliente.longitud != null && (
                  <div className="flex flex-wrap items-center gap-2 text-xs px-3 py-2 rounded-lg bg-green-50 dark:bg-green-900/20 text-green-700 dark:text-green-300">
                    <MapPin className="w-4 h-4" />
                    {gpsAccuracy != null ? (
                      <>
                        <span className="tabular-nums">
                          {nuevoCliente.latitud.toFixed(6)}, {nuevoCliente.longitud.toFixed(6)}
                        </span>
                        <span
                          className="inline-flex items-center gap-1 px-1.5 py-0.5 rounded-full bg-blue-100 dark:bg-blue-900/40 text-blue-700 dark:text-blue-300 text-[10px] font-semibold tracking-wide uppercase"
                          title="Coordenadas capturadas con GPS del dispositivo"
                        >
                          GPS
                        </span>
                        <span
                          className={`inline-flex items-center px-1.5 py-0.5 rounded-full text-[11px] font-medium ${
                            gpsAccuracy > 50
                              ? 'bg-amber-100 dark:bg-amber-900/30 text-amber-700 dark:text-amber-300'
                              : 'bg-green-100 dark:bg-green-900/30 text-green-700 dark:text-green-300'
                          }`}
                        >
                          ±{Math.round(gpsAccuracy)} m
                        </span>
                        {gpsAccuracy > 50 && (
                          <span className="text-amber-700 dark:text-amber-400 text-[11px]">
                            Precisión baja — afiná posición si podés.
                          </span>
                        )}
                      </>
                    ) : (
                      <span>Ubicación guardada</span>
                    )}
                  </div>
                )}
                <FranjasHorariasEditor franjas={franjasAtencion} onChange={setFranjasAtencion} />
                <DiasAtencionSelector valor={diasAtencion} onChange={setDiasAtencion} />
                {errorCliente && (
                  <p className="text-sm text-red-600 bg-red-50 dark:bg-red-900/20 dark:text-red-400 px-3 py-2 rounded-lg">{errorCliente}</p>
                )}
                {duplicadoPendiente && (
                  <button
                    type="button"
                    onClick={() => { void handleConfirmarDuplicadoYCrear(); }}
                    disabled={guardandoCliente}
                    className="w-full py-2 bg-amber-600 text-white rounded-lg hover:bg-amber-700 disabled:bg-amber-400"
                  >
                    {guardandoCliente ? <Loader2 className="w-4 h-4 animate-spin mx-auto" /> : 'Sí, es otro comercio: crear igual'}
                  </button>
                )}
                <Button onClick={handleCrearClienteRapido} disabled={guardandoCliente} variant="primary" size="md" className="w-full">
                  {guardandoCliente ? <Loader2 className="w-4 h-4 animate-spin mx-auto" /> : 'Crear y seleccionar'}
                </Button>
              </div>
            ) : clienteSeleccionado ? (
              <div className="p-3 bg-blue-50 border border-blue-200 rounded-lg flex justify-between items-center">
                <div><p className="font-medium">{clienteSeleccionado.nombre_fantasia}</p><p className="text-sm text-gray-600">{clienteSeleccionado.direccion}</p></div>
                <Button
                  variant="ghost"
                  size="iconSm"
                  onClick={() => onClienteChange('')}
                  aria-label="Quitar cliente"
                  // La tarjeta (bg-blue-50 border-blue-200) no tiene variante dark:,
                  // así que sigue clara en modo oscuro: el className pisa también
                  // dark:text/dark:hover para que el ícono siga siendo rojo sobre
                  // fondo claro en los dos modos, como en el footer de ModalProducto.
                  className="text-red-500 dark:text-red-500 hover:bg-red-50 dark:hover:bg-red-50"
                >
                  <X className="w-5 h-5" />
                </Button>
              </div>
            ) : (
              <div>
                <div className="relative w-full">
                  <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5 pointer-events-none" />
                  <input type="text" value={busquedaCliente} onChange={e => setBusquedaCliente(e.target.value)} autoComplete="off" className="block w-full pl-10 pr-3 py-3 min-h-11 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none" placeholder="Buscar por nombre, razón social o CUIT..." />
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
                        onClick={() => { onClienteChange(c.id.toString()); setBusquedaCliente(''); }}
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

            {/* Deuda previa del cliente elegido. Se muestra acá, en el momento
                en que se lo elige, que es cuando todavía se puede hablar del
                tema con el cliente adelante. Sólo avisa. */}
            {avisoDeuda && (
              <div
                role="status"
                className="mt-3 p-3 rounded-lg border bg-rose-50 border-rose-300 text-sm text-rose-900 dark:bg-rose-900/30 dark:border-rose-700 dark:text-rose-200 flex items-start gap-2"
              >
                <AlertCircle className="w-4 h-4 mt-0.5 flex-shrink-0" aria-hidden="true" />
                <span>{avisoDeuda.detalle}</span>
              </div>
            )}

            {/* Horario faltante del cliente ya seleccionado. Va DENTRO del
                ModalBase (no como modal hermano): un Radix Dialog deja
                cualquier overlay hermano detrás y sería inalcanzable.
                `key` por cliente: al cambiar de cliente el editor se reinicia
                solo, sin efecto de sincronización. */}
            {faltaHorarioCliente && clienteSeleccionado && (
              <div className="mt-3">
                <BloqueHorarioRequerido
                  key={clienteSeleccionado.id}
                  nombreCliente={clienteSeleccionado.nombre_fantasia || clienteSeleccionado.razon_social || 'este cliente'}
                  horarioActual={clienteSeleccionado.horarios_atencion}
                  diasActuales={clienteSeleccionado.dias_atencion}
                  onGuardar={patch => onGuardarHorarioCliente!(String(clienteSeleccionado.id), patch)}
                />
              </div>
            )}
          </div>

          {/* Fechas - pedido y entrega programada */}
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
                <Calendar className="w-4 h-4" />
                Fecha del pedido
              </label>
              <input
                type="date"
                value={nuevoPedido.fecha || fechaLocalISO()}
                onChange={e => onFechaChange && onFechaChange(e.target.value)}
                max={fechaLocalISO()}
                className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
              />
              {nuevoPedido.fecha && nuevoPedido.fecha !== fechaLocalISO() && (
                <p className="mt-1 text-xs text-amber-600">Fecha distinta a hoy</p>
              )}
            </div>
            <div>
              <label className="text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
                <Truck className="w-4 h-4" />
                Fecha de entrega
              </label>
              <input
                type="date"
                value={nuevoPedido.fechaEntregaProgramada || (() => {
                  const base = nuevoPedido.fecha || fechaLocalISO();
                  const d = new Date(base + 'T12:00:00');
                  d.setDate(d.getDate() + 1);
                  return fechaLocalISO(d);
                })()}
                onChange={e => onFechaEntregaProgramadaChange && onFechaEntregaProgramadaChange(e.target.value)}
                min={nuevoPedido.fecha || fechaLocalISO()}
                className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
              />
            </div>
          </div>

          {/* Seccion Productos con filtro por categoria */}
          <div>
            <label className="block text-sm font-medium mb-1 dark:text-gray-200">Agregar Productos</label>

            <div className="relative w-full">
              <Search className="absolute left-3 top-1/2 transform -translate-y-1/2 text-gray-400 w-5 h-5 pointer-events-none" />
              <input type="text" value={busquedaProducto} onChange={e => setBusquedaProducto(e.target.value)} autoComplete="off" className="block w-full pl-10 pr-3 py-3 min-h-11 text-base border rounded-lg dark:bg-gray-700 dark:border-gray-600 dark:text-white focus:ring-2 focus:ring-blue-500 focus:outline-none" placeholder="Buscar producto..." />
            </div>

            {/* Filtros de categoria: carrusel horizontal con flechas */}
            {categorias.length > 0 && (
              <div className="relative mt-2">
                <button
                  type="button"
                  onClick={() => categoriasScrollRef.current?.scrollBy({ left: -160, behavior: 'smooth' })}
                  className="absolute left-0 top-1/2 -translate-y-1/2 z-10 bg-white/95 dark:bg-gray-800 rounded-full p-1 shadow-md border dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700"
                  aria-label="Anterior categoría"
                >
                  <ChevronLeft className="w-4 h-4 text-gray-600 dark:text-gray-300" />
                </button>
                <div
                  ref={categoriasScrollRef}
                  className="flex gap-1.5 overflow-x-auto scroll-smooth px-8 py-1 scrollbar-hide"
                >
                  <button
                    onClick={() => setCategoriaSeleccionada('')}
                    className={`shrink-0 px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
                      categoriaSeleccionada === ''
                        ? 'bg-blue-600 text-white'
                        : 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300'
                    }`}
                  >
                    Todos
                  </button>
                  {categorias.map((cat) => {
                    const catValue = typeof cat === 'string' ? cat : cat.nombre;
                    const catKey = typeof cat === 'string' ? cat : cat.id;
                    return (
                      <button
                        key={catKey}
                        onClick={() => setCategoriaSeleccionada(catValue)}
                        className={`shrink-0 px-2.5 py-1 rounded-full text-xs font-medium transition-colors ${
                          categoriaSeleccionada === catValue
                            ? 'bg-blue-600 text-white'
                            : 'bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-700 dark:text-gray-300'
                        }`}
                      >
                        {catValue}
                      </button>
                    );
                  })}
                </div>
                <button
                  type="button"
                  onClick={() => categoriasScrollRef.current?.scrollBy({ left: 160, behavior: 'smooth' })}
                  className="absolute right-0 top-1/2 -translate-y-1/2 z-10 bg-white/95 dark:bg-gray-800 rounded-full p-1 shadow-md border dark:border-gray-600 hover:bg-gray-50 dark:hover:bg-gray-700"
                  aria-label="Siguiente categoría"
                >
                  <ChevronRight className="w-4 h-4 text-gray-600 dark:text-gray-300" />
                </button>
              </div>
            )}
          </div>

          {/* Lista de productos disponibles - altura adaptativa */}
          <div className="border dark:border-gray-600 rounded-lg max-h-[40vh] sm:max-h-64 overflow-y-auto">
            {productosFiltrados.length === 0 ? (
              <p className="p-4 text-center text-gray-500 dark:text-gray-400">No se encontraron productos</p>
            ) : (
              productosFiltrados.map(p => {
                // Del catálogo completo, NO de `moqMap`: ese sólo cubre lo que
                // ya está en el carrito, así que un producto todavía no
                // agregado daba undefined — entraba con cantidad 1 violando su
                // propio mínimo y sin mostrar el badge "Min: N".
                const moq = obtenerMOQ(String(p.id), minimosProducto)
                const yaAgregado = nuevoPedido.items.some(i => i.productoId === p.id);
                // Sin precio de venta cargado no se puede vender (el backend lo
                // rechaza, mig 139). Se muestra igual —deshabilitado y con el
                // motivo— para que el preventista sepa que el producto existe y
                // pueda pedir que le carguen el precio.
                const sinPrecio = !(Number(p.precio) > 0);
                // Agotado: mismo tratamiento que "sin precio". Se ve, se sabe
                // por qué, y no se puede agregar.
                const sinStock = !sinPrecio && !(Number(p.stock) > 0);
                const noDisponible = sinPrecio || sinStock;
                return (
                  // Botón nativo (#853): Tab llega, Enter y Espacio agregan, y el
                  // nombre accesible sale del contenido (incluye el del producto).
                  // Adentro no hay otros controles, así que puede contenerlo todo;
                  // por eso los bloques de abajo son `span block` y no `div`/`p`
                  // (un botón sólo admite contenido en línea). Agotado o sin
                  // precio: sigue en el orden de Tab con `aria-disabled` —no
                  // `disabled`— para que el lector de pantalla pueda decir por
                  // qué no se puede agregar, y sin `onClick`: Enter no hace nada.
                  <button
                    type="button"
                    key={p.id}
                    className={`w-full text-left flex justify-between items-center px-3 py-2.5 border-b dark:border-gray-600 transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-blue-500 ${
                      noDisponible
                        ? 'opacity-60 cursor-not-allowed bg-stone-50 dark:bg-gray-900/40'
                        : yaAgregado
                          ? 'bg-blue-50 dark:bg-blue-900/20 cursor-pointer'
                          : 'hover:bg-gray-50 dark:hover:bg-gray-700 cursor-pointer'
                    }`}
                    onClick={noDisponible ? undefined : () => onAgregarItem(p.id, moq || 1)}
                    aria-disabled={noDisponible}
                    title={
                      sinPrecio
                        ? 'Pendiente de carga de precio de venta: no se puede vender'
                        : sinStock
                          ? 'Sin stock disponible: no se puede vender'
                          : undefined
                    }
                  >
                    <span className="min-w-0 flex-1">
                      <span className="block font-medium text-sm dark:text-white truncate">{p.nombre}</span>
                      <span className="block text-xs text-gray-500 dark:text-gray-400">
                        Stock: {p.stock}
                        {p.categoria && <span className="ml-1.5 px-1.5 py-0.5 bg-gray-100 dark:bg-gray-600 rounded text-xs">{p.categoria}</span>}
                        {moq && moq > 1 && <span className="ml-1.5 px-1.5 py-0.5 bg-amber-100 text-amber-700 rounded text-xs font-medium">Min: {moq}</span>}
                      </span>
                    </span>
                    <span className="text-right ml-3 shrink-0">
                      {sinPrecio ? (
                        <>
                          <span className="block font-semibold text-xs text-rose-600 dark:text-rose-400">Sin precio</span>
                          <span className="text-xs text-stone-600 dark:text-gray-400">No disponible</span>
                        </>
                      ) : sinStock ? (
                        <>
                          <span className="block font-semibold text-xs text-rose-600 dark:text-rose-400">Sin stock</span>
                          <span className="text-xs text-stone-600 dark:text-gray-400">No disponible</span>
                        </>
                      ) : (
                        <>
                          <span className="block font-semibold text-sm text-blue-600 dark:text-blue-400">{formatPrecio(p.precio)}</span>
                          <span className="text-xs text-blue-500">{yaAgregado ? '+ Mas' : '+ Agregar'}</span>
                        </>
                      )}
                    </span>
                  </button>
                )
              })
            )}
          </div>

          </div>

          {/* Drawer overlay: cubre el área del modal con slide-up */}
          <div
            id="carrito-drawer"
            className={`absolute inset-0 z-20 bg-white dark:bg-gray-800 flex flex-col transition-transform duration-300 ease-out ${
              carritoAbierto ? 'translate-y-0' : 'translate-y-full pointer-events-none'
            }`}
            aria-hidden={!carritoAbierto}
          >
            <div className="flex-1 overflow-y-auto overscroll-contain p-4 space-y-4 min-h-0">
              {/* Deuda previa del cliente (avisa, NO bloquea). Va primero: es lo
                  único de este bloque que no impide confirmar, y repetirlo acá
                  es para que no se pierda si el carrito se armó largo. */}
              {avisoDeuda && (
                <div role="status" className="p-3 bg-rose-50 border border-rose-300 rounded-lg text-sm text-rose-900 dark:bg-rose-900/30 dark:border-rose-700 dark:text-rose-200">
                  {avisoDeuda.detalle}
                </div>
              )}

              {/* Reparto del regalo que no cierra (bloquea confirmar) */}
              {repartosRegaloInvalidos.length > 0 && (
                <div role="alert" className="p-3 bg-amber-50 border border-amber-300 rounded-lg text-sm text-amber-900 dark:bg-amber-900/30 dark:border-amber-600 dark:text-amber-200">
                  <strong>No se puede confirmar:</strong> el reparto del regalo no cierra.
                  <ul className="list-disc ml-5 mt-1">
                    {repartosRegaloInvalidos.map(r => (
                      <li key={r.promoNombre}>{r.promoNombre}: {r.errores.join('. ')}</li>
                    ))}
                  </ul>
                </div>
              )}

              {/* Compra mínima del pedido (bloquea confirmar) */}
              {motivoMinimo && (
                <div role="alert" className="p-3 bg-amber-50 border border-amber-300 rounded-lg text-sm text-amber-900 dark:bg-amber-900/30 dark:border-amber-600 dark:text-amber-200">
                  <strong>No se puede confirmar:</strong> {motivoMinimo}
                </div>
              )}

              {/* Violaciones MOQ (bloquean confirmar) */}
              {violacionesMOQ.length > 0 && (
                <div role="alert" className="p-3 bg-amber-50 border border-amber-300 rounded-lg text-sm text-amber-900 dark:bg-amber-900/30 dark:border-amber-600 dark:text-amber-200">
                  <strong>No se puede confirmar:</strong> los siguientes productos no cumplen el mínimo de compra:
                  <ul className="list-disc ml-5 mt-1">
                    {violacionesMOQ.map(v => {
                      const producto = productos.find(p => p.id === v.productoId);
                      const nombre = producto?.nombre || v.productoId;
                      return (
                        <li key={v.productoId}>
                          {nombre}: mínimo {v.cantidadMinima}, cargaste {v.cantidadActual}
                        </li>
                      );
                    })}
                  </ul>
                </div>
              )}

              {/* Faltantes de stock (bloquean confirmar) */}
              {violacionesStock.length > 0 && (
                <div role="alert" className="p-3 bg-rose-50 border border-rose-300 rounded-lg text-sm text-rose-900 dark:bg-rose-900/30 dark:border-rose-600 dark:text-rose-200">
                  <strong>No se puede confirmar:</strong> no hay stock suficiente para:
                  <ul className="list-disc ml-5 mt-1">
                    {violacionesStock.map(v => (
                      <li key={v.productoId}>
                        {v.nombre}: disponible {v.disponible}, cargaste {v.solicitado}
                      </li>
                    ))}
                  </ul>
                </div>
              )}

              {/* Items del pedido */}
              {nuevoPedido.items.length > 0 ? (
                <div>
                  <h3 className="font-medium mb-2 dark:text-white text-sm">Productos en el pedido ({nuevoPedido.items.length})</h3>
                  <div className="border dark:border-gray-600 rounded-lg divide-y dark:divide-gray-600">
                    {nuevoPedido.items.map(item => {
                        const prod = productos.find(p => p.id === item.productoId);
                        const warning = getStockWarning(item.productoId, item.cantidad);
                        const precioInfo = preciosResueltos.get(String(item.productoId));
                        const esOverride = item.precioOverride || false;
                        const esMayorista = !esOverride && (precioInfo?.esMayorista || false);
                        const precioBase = esOverride ? item.precioUnitario : (esMayorista ? precioInfo!.precioResuelto : item.precioUnitario);
                        // Descuento del cliente sobre el precio efectivo (no sobre override).
                        const pctCliente = esOverride ? 0 : resolverDescuentoPctCliente(clienteSeleccionado, prod?.categoria);
                        const precioMostrar = pctCliente > 0 && precioBase > 0
                          ? Math.round(precioBase * (1 - pctCliente / 100) * 100) / 100
                          : precioBase;
                        const subtotal = precioMostrar * item.cantidad;
                        const itemMoq = moqMap.get(String(item.productoId));
                        const minCantidad = itemMoq && itemMoq > 1 ? itemMoq : 1;
                        const isEditingPrice = editingPriceId === item.productoId;
                        return (
                          <div key={item.productoId} className="px-3 py-2.5">
                            <div className="flex flex-col sm:flex-row sm:justify-between sm:items-center gap-2">
                              <div className="min-w-0 sm:flex-1">
                                <div className="flex items-center gap-1.5 flex-wrap">
                                  <p className="font-medium text-sm dark:text-white sm:truncate break-words">{prod?.nombre}</p>
                                  {esOverride && (
                                    <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-orange-100 text-orange-700 rounded-full font-medium shrink-0">
                                      <Pencil className="w-3 h-3" />
                                      Manual
                                    </span>
                                  )}
                                  {esMayorista && (
                                    <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-green-100 text-green-700 rounded-full font-medium shrink-0">
                                      <Tag className="w-3 h-3" />
                                      {precioInfo?.etiqueta || 'Mayorista'}
                                    </span>
                                  )}
                                  {pctCliente > 0 && (
                                    <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-emerald-100 text-emerald-700 rounded-full font-medium shrink-0">
                                      <Percent className="w-3 h-3" />
                                      -{pctCliente}%
                                    </span>
                                  )}
                                </div>
                                {isEditingPrice && isAdmin && onActualizarPrecio ? (
                                  <div className="flex items-center gap-1 mt-0.5">
                                    <span className="text-xs text-orange-600">$</span>
                                    <input
                                      ref={precioInputRef}
                                      type="number"
                                      inputMode="decimal"
                                      step="0.01"
                                      min="0.01"
                                      value={editingPriceValue}
                                      onChange={e => setEditingPriceValue(e.target.value)}
                                      onKeyDown={e => {
                                        if (e.key === 'Enter') {
                                          precioResueltoRef.current = true;
                                          const newPrice = parsePrecio(editingPriceValue);
                                          if (newPrice > 0) onActualizarPrecio(item.productoId, newPrice);
                                          setEditingPriceId(null);
                                        } else if (e.key === 'Escape') {
                                          precioResueltoRef.current = true;
                                          setEditingPriceId(null);
                                        }
                                      }}
                                      onBlur={() => {
                                        if (precioResueltoRef.current) return;
                                        const newPrice = parsePrecio(editingPriceValue);
                                        if (newPrice > 0) onActualizarPrecio(item.productoId, newPrice);
                                        setEditingPriceId(null);
                                      }}
                                      className="w-24 px-2 py-0.5 text-xs border border-orange-300 rounded bg-orange-50 dark:bg-orange-900/20 dark:border-orange-600 dark:text-white focus:ring-1 focus:ring-orange-500 focus:outline-none"
                                      autoFocus
                                    />
                                    <span className="text-xs text-orange-600">c/u</span>
                                  </div>
                                ) : esOverride ? (
                                  <p
                                    className={`text-xs text-orange-600 font-medium ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                                    onClick={() => {
                                      if (isAdmin && onActualizarPrecio) {
                                        setEditingPriceId(item.productoId);
                                        setEditingPriceValue(String(item.precioUnitario));
                                      }
                                    }}
                                  >
                                    {formatPrecio(item.precioUnitario)} c/u {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-0.5" />}
                                  </p>
                                ) : esMayorista ? (
                                  <p className={`text-xs ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                                    onClick={() => {
                                      if (isAdmin && onActualizarPrecio) {
                                        setEditingPriceId(item.productoId);
                                        setEditingPriceValue(String(precioInfo!.precioResuelto));
                                      }
                                    }}
                                  >
                                    <span className="text-gray-400 line-through">{formatPrecio(item.precioUnitario)}</span>
                                    <span className="ml-1 text-green-600 font-medium">{formatPrecio(precioInfo!.precioResuelto)} c/u</span>
                                    {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-1 text-gray-400" />}
                                  </p>
                                ) : (
                                  <p
                                    className={`text-xs text-gray-500 dark:text-gray-400 ${isAdmin && onActualizarPrecio ? 'cursor-pointer hover:underline' : ''}`}
                                    onClick={() => {
                                      if (isAdmin && onActualizarPrecio) {
                                        setEditingPriceId(item.productoId);
                                        setEditingPriceValue(String(item.precioUnitario));
                                      }
                                    }}
                                  >
                                    {formatPrecio(item.precioUnitario)} c/u {isAdmin && onActualizarPrecio && <Pencil className="w-3 h-3 inline ml-0.5 text-gray-400" />}
                                  </p>
                                )}
                                {pctCliente > 0 && (
                                  <p className="text-xs text-emerald-600 font-medium mt-0.5">
                                    Descuento cliente -{pctCliente}%: {formatPrecio(precioMostrar)} c/u
                                  </p>
                                )}
                                {itemMoq && itemMoq > 1 && (
                                  <p className="text-xs text-amber-600 mt-0.5">Min: {itemMoq} uds</p>
                                )}
                              </div>
                              <div className="flex items-center gap-2 shrink-0 self-end sm:self-auto">
                                <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, 0); }} className="p-1 text-red-500 hover:bg-red-50 dark:hover:bg-red-900/20 rounded" title="Eliminar producto"><Trash2 className="w-4 h-4" /></button>
                                <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, Math.max(item.cantidad - 1, minCantidad)); }} className={`w-7 h-7 rounded-full text-sm ${item.cantidad <= minCantidad ? 'bg-gray-100 text-gray-400 dark:bg-gray-700' : 'bg-gray-200 hover:bg-gray-300 dark:bg-gray-600 dark:hover:bg-gray-500'}`} disabled={item.cantidad <= minCantidad}>-</button>
                                <NumberInput
                                  integer
                                  min={minCantidad}
                                  emptyValue={minCantidad}
                                  value={item.cantidad}
                                  onChange={(n) => onActualizarCantidad(item.productoId, Math.max(n, minCantidad))}
                                  onClick={(e) => e.stopPropagation()}
                                  aria-label="Cantidad"
                                  className="w-12 text-center font-medium text-sm border dark:border-gray-600 rounded px-1 py-0.5 dark:bg-gray-700 dark:text-white focus:outline-none focus:ring-1 focus:ring-blue-500"
                                />
                                <button onClick={(e) => { e.stopPropagation(); onActualizarCantidad(item.productoId, item.cantidad + 1); }} className="w-7 h-7 rounded-full text-sm bg-gray-200 hover:bg-gray-300 dark:bg-gray-600 dark:hover:bg-gray-500">+</button>
                                <p className="w-20 text-right font-semibold text-sm dark:text-white">{formatPrecio(subtotal)}</p>
                              </div>
                            </div>
                            {warning && <p className={`text-xs mt-1 ${warning.tipo === 'error' ? 'text-red-600' : 'text-yellow-600'}`}>{warning.mensaje}</p>}
                          </div>
                        );
                      })}
                      {/* Items de bonificación (gratis). Una promo repartida en
                          sabores son varias líneas: se muestran juntas, en un
                          bloque por promo. */}
                      {gruposBonif.map(grupo => {
                        const prodPrincipal = productos.find(p => String(p.id) === String(grupo.lineas[0].productoId));
                        // En modo Fracción descripcionRegalo describe el regalo
                        // como lo cargó el admin (ej: "1 botella Manaos Naranja
                        // 600cc"). Si no hay, fallback al nombre del producto.
                        const labelRegalo = grupo.lineas.length > 1
                          ? 'Regalo repartido'
                          : (grupo.lineas[0].descripcionRegalo?.trim() || prodPrincipal?.nombre);
                        const puedeElegir = isAdmin && !!onCambiarRegaloCreacion && !!grupo.promoId;
                        const partes = puedeElegir ? partesDeGrupo(grupo) : [];
                        const esReparto = partes.length > 1;
                        const validacion = esReparto
                          ? validarRepartoRegalo(partes, grupo.total, grupo.productoDefaultId)
                          : null;
                        const opciones = puedeElegir ? opcionesRegaloDePromo(grupo) : [];
                        const cambiarPartes = (nuevas: ParteReparto[]) =>
                          onCambiarRegaloCreacion?.(String(grupo.promoId), nuevas);
                        return (
                          <div key={grupo.key} className="px-3 py-2.5 bg-green-50 dark:bg-green-900/10">
                            <div className="flex justify-between items-center gap-2">
                              <div className="min-w-0 flex-1">
                                <div className="flex items-center gap-1.5">
                                  <p className="font-medium text-sm text-green-700 dark:text-green-400 truncate">{labelRegalo}</p>
                                  <span className="inline-flex items-center gap-0.5 text-xs px-1.5 py-0.5 bg-green-200 text-green-800 rounded-full font-medium shrink-0">
                                    <Gift className="w-3 h-3" />
                                    Bonificacion
                                  </span>
                                </div>
                                <p className="text-xs text-green-600 dark:text-green-400">{grupo.promoNombre}</p>
                                {/* Quien no elige el regalo ve el reparto como lista. */}
                                {!puedeElegir && grupo.lineas.length > 1 && (
                                  <ul className="text-xs text-green-700 dark:text-green-400">
                                    {grupo.lineas.map(l => (
                                      <li key={String(l.productoId)}>
                                        {l.cantidadBonificacion} de {productos.find(p => String(p.id) === String(l.productoId))?.nombre ?? l.productoId}
                                      </li>
                                    ))}
                                  </ul>
                                )}
                              </div>
                              <div className="flex items-center gap-2 shrink-0">
                                <span className="w-6 text-center font-medium text-sm text-green-700 dark:text-green-400">{grupo.total}</span>
                                <p className="w-20 text-right font-semibold text-sm text-green-600">GRATIS</p>
                                {(isAdmin || isPreventista || isEncargado) && onEliminarPromoCreacion && grupo.promoId && (
                                  <button
                                    type="button"
                                    onClick={() => setConfirmConfig({
                                      visible: true,
                                      tipo: 'warning',
                                      titulo: 'Quitar promoción',
                                      mensaje: `¿Quitar la promoción "${grupo.promoNombre}" de este pedido? El cliente no recibirá la bonificación.`,
                                      onConfirm: () => {
                                        setConfirmConfig(null);
                                        onEliminarPromoCreacion(String(grupo.promoId), grupo.promoNombre);
                                      },
                                    })}
                                    className="p-1 text-red-500 hover:bg-red-100 dark:hover:bg-red-900/30 rounded"
                                    title="Quitar esta promoción del pedido"
                                    aria-label="Quitar promoción"
                                  >
                                    <X className="w-4 h-4" />
                                  </button>
                                )}
                              </div>
                            </div>
                            {/* Admin: elegir el producto del regalo al crear, o
                                repartirlo en varios sabores de la misma promo. */}
                            {puedeElegir && (
                              <div className="mt-1 space-y-1">
                                {partes.map((parte, idx) => {
                                  const prodParte = productos.find(p => String(p.id) === String(parte.productoId));
                                  // El regalo ya elegido sigue visible aunque se haya desactivado.
                                  const opcionesFila = prodParte && !opciones.some(o => String(o.id) === String(prodParte.id))
                                    ? [prodParte, ...opciones]
                                    : opciones;
                                  return (
                                    <div key={idx} className="flex items-center gap-2">
                                      <Combobox<ProductoDB>
                                        aria-label={esReparto ? `Producto del regalo ${idx + 1}` : 'Cambiar el producto del regalo'}
                                        className="w-full max-w-xs min-w-0"
                                        inputClassName="text-xs px-2 py-1 sm:text-xs border-green-300 dark:border-green-700 rounded bg-white"
                                        opciones={opcionesFila}
                                        getKey={getKeyProductoRegalo}
                                        getLabel={getLabelProductoRegalo}
                                        renderOpcion={renderOpcionProductoRegalo}
                                        valor={parte.productoId ? String(parte.productoId) : null}
                                        onSeleccionar={p => cambiarPartes(partes.map((f, i) => (i === idx ? { ...f, productoId: String(p.id) } : f)))}
                                        placeholder="Buscar producto..."
                                        textoSinResultados="Ningun producto coincide"
                                        limite={1000}
                                      />
                                      {esReparto && (
                                        <>
                                          <NumberInput
                                            integer
                                            aria-label={`Cantidad del regalo ${idx + 1}`}
                                            min={0}
                                            emptyValue={0}
                                            commitOnChange
                                            value={Number(parte.cantidad) || 0}
                                            onChange={(n) => cambiarPartes(partes.map((f, i) => (i === idx ? { ...f, cantidad: n } : f)))}
                                            className="w-14 text-center text-xs border border-green-300 dark:border-green-700 rounded px-1 py-1 bg-white dark:bg-gray-700 dark:text-white"
                                          />
                                          <button
                                            type="button"
                                            onClick={() => cambiarPartes(partes.filter((_, i) => i !== idx))}
                                            className="p-1 text-red-500 hover:bg-red-100 dark:hover:bg-red-900/30 rounded shrink-0"
                                            aria-label={`Quitar sabor ${idx + 1}`}
                                            title="Quitar este sabor del reparto"
                                          >
                                            <Trash2 className="w-3.5 h-3.5" />
                                          </button>
                                        </>
                                      )}
                                    </div>
                                  );
                                })}
                                <p className="text-xs text-green-700 dark:text-green-400">
                                  {TEXTO_REGALO_MISMA_CATEGORIA}
                                </p>
                                <div className="flex flex-wrap items-center justify-between gap-2">
                                  {opciones.length > 1 && (
                                    <button
                                      type="button"
                                      onClick={() => {
                                        // Con una sola fila la cantidad sigue a la promo: al
                                        // abrir el reparto, la primera arranca con todo.
                                        const base = partes.length === 1 ? [{ ...partes[0], cantidad: grupo.total }] : partes;
                                        const asignado = base.reduce((acc, f) => acc + (Number(f.cantidad) || 0), 0);
                                        cambiarPartes([...base, { productoId: '', cantidad: Math.max(grupo.total - asignado, 0) }]);
                                      }}
                                      className="inline-flex items-center gap-1 text-xs font-medium text-green-700 dark:text-green-300 hover:underline"
                                    >
                                      <Plus className="w-3.5 h-3.5" />
                                      Repartir en otro sabor
                                    </button>
                                  )}
                                  {esReparto && validacion && (
                                    <p
                                      className={`text-xs font-medium ${validacion.faltante === 0
                                        ? 'text-green-700 dark:text-green-300'
                                        : 'text-amber-700 dark:text-amber-300'}`}
                                      aria-live="polite"
                                    >
                                      Asignado {validacion.asignado} de {grupo.total}
                                      {validacion.faltante > 0 ? ` · faltan ${validacion.faltante}` : ''}
                                      {validacion.faltante < 0 ? ` · sobran ${-validacion.faltante}` : ''}
                                    </p>
                                  )}
                                </div>
                                {validacion && !validacion.ok && (
                                  <p className="text-xs text-amber-700 dark:text-amber-300">
                                    {validacion.errores.join('. ')}.
                                  </p>
                                )}
                              </div>
                            )}
                          </div>
                        );
                      })}
                      {/* Promos quitadas a mano — se pueden restaurar */}
                      {(promosEliminadas ?? []).map(p => (
                        <div key={`promo-quitada-${p.promoId}`} className="px-3 py-2 bg-gray-50 dark:bg-gray-800/40 flex items-center justify-between gap-2">
                          <p className="text-xs text-gray-500 dark:text-gray-400 min-w-0 truncate">
                            Promoción quitada: <span className="font-medium">{p.promoNombre}</span>
                          </p>
                          {onRestaurarPromoCreacion && (
                            <button
                              type="button"
                              onClick={() => onRestaurarPromoCreacion(p.promoId)}
                              className="text-xs font-medium text-indigo-600 dark:text-indigo-400 hover:underline shrink-0"
                            >
                              Restaurar
                            </button>
                          )}
                        </div>
                      ))}
                    </div>

                    {/* Nudges para alcanzar siguiente tier */}
                    {faltantes.length > 0 && (
                      <div className="mt-2 space-y-1">
                        {faltantes.map((f, i) => (
                          <p key={i} className="text-xs text-blue-600 bg-blue-50 dark:bg-blue-900/20 px-3 py-1.5 rounded-lg">
                            Agrega {f.faltante} mas de <strong>{f.grupoNombre}</strong> para precio {f.etiqueta || 'mayorista'} ({formatPrecio(f.precioTier)} c/u)
                          </p>
                        ))}
                      </div>
                    )}

                    {/* Nudges para alcanzar bonificación */}
                    {faltantesBonificacion.length > 0 && (
                      <div className="mt-2 space-y-1">
                        {faltantesBonificacion.map((f, i) => {
                          const prod = productos.find(p => p.id === f.productoId);
                          return (
                            <p key={`bonif-nudge-${i}`} className="text-xs text-green-600 bg-green-50 dark:bg-green-900/20 px-3 py-1.5 rounded-lg">
                              Agrega {f.faltante} mas de <strong>{prod?.nombre || f.promoNombre}</strong> y te llevas {f.bonificacion} gratis!
                            </p>
                          );
                        })}
                      </div>
                    )}
                  </div>
                ) : (
                  <p className="text-center text-sm text-gray-500 dark:text-gray-400 py-6">
                    El carrito está vacío. Agregá productos arriba.
                  </p>
                )}

                {/* Forma de Pago + Estado */}
                <div className="border-t dark:border-gray-600 pt-3 space-y-3">
                  <div className="grid grid-cols-2 gap-3">
                    <div>
                      <label className="block text-sm font-medium mb-1 dark:text-gray-200">Forma de Pago</label>
                      <select
                        value={nuevoPedido.formaPago || 'efectivo'}
                        onChange={e => onFormaPagoChange && onFormaPagoChange(e.target.value)}
                        className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                      >
                        <option value="efectivo">Efectivo</option>
                        <option value="transferencia">Transferencia</option>
                        <option value="cheque">Cheque</option>
                        <option value="tarjeta">Tarjeta</option>
                      </select>
                    </div>
                    <div>
                      <label className="block text-sm font-medium mb-1 dark:text-gray-200">Estado de Pago</label>
                      {/* Sin red el cobro NO se puede declarar: el pedido se
                          encola y el replay no registra pagos, así que un
                          "pagado" offline entraría impago igual y el chofer se lo
                          cobraría de nuevo al cliente. Se fuerza 'pendiente' y se
                          dice por qué, en vez de aceptar algo que no se cumple. */}
                      <select
                        value={isOffline ? 'pendiente' : (nuevoPedido.estadoPago || 'pendiente')}
                        onChange={e => onEstadoPagoChange && onEstadoPagoChange(e.target.value)}
                        disabled={isOffline}
                        className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm disabled:bg-gray-100 disabled:text-gray-500 disabled:cursor-not-allowed dark:disabled:bg-gray-800"
                      >
                        <option value="pendiente">Pendiente</option>
                        <option value="pagado">Pagado</option>
                        <option value="parcial">Parcial</option>
                      </select>
                      {isOffline && (
                        <p className="mt-1 text-xs text-amber-700 dark:text-amber-400">
                          Sin conexión el cobro se registra después, desde la ficha del pedido.
                        </p>
                      )}
                    </div>
                  </div>

                  {/* Preventista asignado (solo admin). Permite que admin
                      cargue un pedido en nombre de un preventista que lo
                      tomo en persona pero no lo subio a la app — asi cuenta
                      en sus etiquetas, estadisticas y comisiones. */}
                  {isAdmin && preventistasAsignables.length > 0 && (
                    <div>
                      <label className="block text-sm font-medium mb-1 dark:text-gray-200 flex items-center gap-1">
                        <UserCheck className="w-4 h-4 text-blue-600" />
                        Preventista asignado *
                      </label>
                      <select
                        value={preventistaSeleccionado}
                        onChange={e => onPreventistaChange?.(e.target.value)}
                        className={`w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:text-white text-sm ${debeElegirPreventista ? 'border-amber-500 ring-1 ring-amber-500' : 'dark:border-gray-600'}`}
                      >
                        <option value="">— Elegí quién vende —</option>
                        {preventistasAsignables.map(p => (
                          <option key={p.id} value={p.id}>
                            {p.nombre}{p.id === currentUserId ? ' (vos)' : ''}
                          </option>
                        ))}
                      </select>
                      {debeElegirPreventista && (
                        <p className="text-xs text-amber-600 dark:text-amber-400 mt-1">
                          Elegí a quién se le acredita la venta (a vos o al preventista que la hizo).
                        </p>
                      )}
                    </div>
                  )}

                  {/* Monto pagado si es pago parcial */}
                  {nuevoPedido.estadoPago === 'parcial' && (
                    <div className="p-3 bg-yellow-50 dark:bg-yellow-900/20 border border-yellow-200 dark:border-yellow-700 rounded-lg">
                      <label className="block text-sm font-medium mb-1 text-yellow-800 dark:text-yellow-300">Monto del pago parcial *</label>
                      <div className="flex items-center gap-2">
                        <span className="text-lg font-semibold text-yellow-700 dark:text-yellow-400">$</span>
                        <input
                          type="number"
                          inputMode="decimal"
                          min="0"
                          step="0.01"
                          max={totalParaMostrar}
                          value={nuevoPedido.montoPagado || ''}
                          onChange={e => onMontoPagadoChange && onMontoPagadoChange(parsePrecio(e.target.value))}
                          className="flex-1 px-3 py-2 border border-yellow-300 rounded-lg focus:ring-2 focus:ring-yellow-500 bg-white dark:bg-gray-800 dark:border-yellow-600 dark:text-white"
                          placeholder="Ingrese el monto pagado"
                        />
                      </div>
                      {(nuevoPedido.montoPagado ?? 0) > 0 && (
                        <p className="text-sm text-yellow-700 dark:text-yellow-300 mt-2">
                          Resta por pagar: {formatPrecio(totalParaMostrar - (nuevoPedido.montoPagado ?? 0))}
                        </p>
                      )}
                    </div>
                  )}

                  <div>
                    <label className="block text-sm font-medium mb-1 dark:text-gray-200">Observaciones</label>
                    <textarea
                      value={nuevoPedido.notas || ''}
                      onChange={e => onNotasChange && onNotasChange(e.target.value)}
                      className="w-full px-3 py-2 border rounded-lg bg-white dark:bg-gray-700 dark:border-gray-600 dark:text-white text-sm"
                      placeholder="Observaciones para la preparacion..."
                      rows={2}
                    />
                  </div>
                </div>

              {/* Total detallado */}
              <div className="border-t dark:border-gray-600 pt-3 flex justify-between items-center">
                <span className="text-base font-medium dark:text-white">Total</span>
                <div className="text-right">
                  {hayDescuentoTotal ? (
                    <>
                      <span className="text-xs text-gray-400 line-through mr-2">{formatPrecio(totalOriginal)}</span>
                      <span className="text-xl font-bold text-green-600">{formatPrecio(totalConDescuentoCliente)}</span>
                      <p className="text-xs text-green-600 font-medium">Ahorro: {formatPrecio(totalOriginal - totalConDescuentoCliente)}</p>
                    </>
                  ) : (
                    <span className="text-xl font-bold text-blue-600">{formatPrecio(calcularTotal())}</span>
                  )}
                </div>
              </div>
            </div>
          </div>
        </div>

        {/* Aviso del horario faltante en la barra inferior: el bloque para
            cargarlo está arriba y puede quedar fuera de la vista con el
            carrito lleno. */}
        {faltaHorarioCliente && (
          <div role="alert" className="flex-shrink-0 px-4 py-1.5 bg-amber-100 dark:bg-amber-900/40 border-t border-amber-300 dark:border-amber-700 text-xs text-amber-900 dark:text-amber-200">
            Falta cargar el horario del cliente — subí para completarlo.
          </div>
        )}

        {/* Sin conexión: se dice antes de cargar, no al confirmar. El pedido NO
            se pierde — se guarda en el teléfono y sincroniza solo. */}
        {isOffline && (
          <div role="status" className="flex-shrink-0 px-4 py-1.5 bg-orange-100 dark:bg-orange-900/40 border-t border-orange-300 dark:border-orange-700 text-xs text-orange-900 dark:text-orange-200">
            Sin conexión — el pedido se guarda en el teléfono y se sincroniza solo cuando vuelva la señal.
          </div>
        )}

        {/* Aviso compacto de faltantes de stock (siempre visible cuando aplican) */}
        {violacionesStock.length > 0 && (
          <div role="alert" className="flex-shrink-0 px-4 py-1.5 bg-rose-100 dark:bg-rose-900/40 border-t border-rose-300 dark:border-rose-700 text-xs text-rose-900 dark:text-rose-200">
            {violacionesStock.length} producto{violacionesStock.length > 1 ? 's sin' : ' sin'} stock suficiente — revisá el carrito.
          </div>
        )}

        {/* Aviso compacto del reparto del regalo (siempre visible cuando aplica) */}
        {repartosRegaloInvalidos.length > 0 && (
          <div role="alert" className="flex-shrink-0 px-4 py-1.5 bg-amber-100 dark:bg-amber-900/40 border-t border-amber-300 dark:border-amber-700 text-xs text-amber-900 dark:text-amber-200">
            El reparto del regalo no suma la bonificación — revisá el carrito.
          </div>
        )}

        {/* Aviso compacto de compra mínima (siempre visible cuando aplica) */}
        {motivoMinimo && (
          <div role="alert" className="flex-shrink-0 px-4 py-1.5 bg-amber-100 dark:bg-amber-900/40 border-t border-amber-300 dark:border-amber-700 text-xs text-amber-900 dark:text-amber-200">
            {motivoMinimo}
          </div>
        )}

        {/* Aviso compacto de violaciones (siempre visible cuando aplican) */}
        {violacionesMOQ.length > 0 && (
          <div role="alert" className="flex-shrink-0 px-4 py-1.5 bg-amber-100 dark:bg-amber-900/40 border-t border-amber-300 dark:border-amber-700 text-xs text-amber-900 dark:text-amber-200">
            {violacionesMOQ.length} producto{violacionesMOQ.length > 1 ? 's no cumplen' : ' no cumple'} el mínimo — revisá el carrito.
          </div>
        )}

        {/* Barra inferior: toggle del carrito + Confirmar (siempre visibles).
            En el sheet llega al borde de la pantalla: Confirmar necesita aire a
            la derecha y abajo (y el área segura de los celulares con muesca),
            o en un celular chico queda pegado al borde. En el diálogo el borde
            es el del diálogo, y queda como estaba. */}
        <div className={enSheet
          ? 'flex items-stretch gap-2 border-t dark:border-gray-600 flex-shrink-0 bg-white dark:bg-gray-800 pt-2 pb-3 pl-[max(0.5rem,env(safe-area-inset-left))] pr-[max(0.75rem,env(safe-area-inset-right))]'
          : 'flex items-stretch border-t dark:border-gray-600 flex-shrink-0 bg-white dark:bg-gray-800'}>
          <button
            type="button"
            onClick={() => setCarritoAbierto(v => !v)}
            disabled={!hayItems}
            aria-expanded={carritoAbierto}
            aria-controls="carrito-drawer"
            className="flex-1 min-w-0 px-3 sm:px-4 py-3 flex items-center justify-between gap-2 active:bg-gray-50 dark:active:bg-gray-700 disabled:opacity-60 disabled:cursor-not-allowed"
          >
            <span className="flex items-center gap-2 min-w-0">
              <ShoppingCart className="w-5 h-5 text-gray-600 dark:text-gray-300 shrink-0" />
              <span className="font-medium text-sm dark:text-white truncate">
                {/* En el celular la palabra queda sólo para el lector de
                    pantalla y se ve el número: si no, un total de seis cifras
                    no entra al lado de Confirmar. */}
                {hayItems
                  ? <>
                      <span className="max-sm:sr-only">{`${totalItemsCarrito} ${totalItemsCarrito === 1 ? 'unidad' : 'unidades'}`}</span>
                      <span aria-hidden="true" className="sm:hidden">{totalItemsCarrito}</span>
                    </>
                  : 'Sin productos'}
              </span>
              {hayItems && (
                <span className={`font-bold text-sm truncate ${hayDescuentoTotal ? 'text-green-600' : 'text-blue-600 dark:text-blue-400'}`}>
                  {formatPrecio(totalParaMostrar)}
                </span>
              )}
            </span>
            {hayItems && (
              <ChevronUp className={`w-5 h-5 text-gray-600 dark:text-gray-300 shrink-0 max-[359px]:hidden transition-transform duration-200 ${carritoAbierto ? 'rotate-180' : ''}`} />
            )}
          </button>
          <Button
            type="button"
            onClick={onGuardar}
            // `!nuevoPedido.clienteId` (#732): sin cliente el botón quedaba
            // habilitado y sólo lo frenaba un aviso del container. Se mira el
            // id y no `clienteSeleccionado`: un cliente recién creado por el
            // alta rápida tiene id antes de que la lista de clientes refetchee.
            disabled={guardando || !nuevoPedido.clienteId || violacionesMOQ.length > 0 || violacionesStock.length > 0 || !hayItems || debeElegirPreventista || faltaHorarioCliente || motivoMinimo !== null || repartosRegaloInvalidos.length > 0}
            loading={guardando}
            variant="success"
            size="lg"
            // shrink-0: en un celular de 320 px el toggle del carrito (con el
            // total) lo empujaba fuera de la pantalla; el que se achica y corta
            // su texto es el toggle (min-w-0), nunca Confirmar.
            className="gap-1.5 shrink-0"
          >
            Confirmar
          </Button>
        </div>
      </GeolocationGate>
  );

  // La confirmación de quitar promo va DENTRO del envoltorio en los dos casos:
  // como hermano quedaría detrás del overlay (ver `confirmConfig`).
  const confirmacion = <ModalConfirmacion config={confirmConfig} onClose={() => setConfirmConfig(null)} />;

  if (enSheet) {
    return (
      <BottomSheet
        open
        onClose={onClose}
        title="Nuevo Pedido"
        headerExtra={tipoFacturaToggle}
        // Igual que ModalBase: un toque al costado no tira el pedido a medio
        // armar. Escape y la X siguen cerrando.
        cerrarAlTocarAfuera={false}
        bodyBare
        // Diálogo de verdad (aria-modal, foco devuelto al cerrar) y apoyado
        // sobre el teclado del celular: la barra con Confirmar tiene que
        // quedar a la vista. Son opt-in en BottomSheet: ModalFiltrosPedidos no
        // los pide y queda como estaba.
        comoDialogo
        ajustarTeclado
        // dvh: el alto que queda con la barra del navegador a la vista. El
        // teclado no lo cambia; de eso se ocupa `ajustarTeclado`.
        maxHeight={ALTO_SHEET}
      >
        {/* El mismo boundary que ModalBase pone alrededor del cuerpo: si algo
            tira adentro, el sheet sigue teniendo título y X. */}
        <CompactErrorBoundary componentName="Nuevo Pedido" onClose={onClose}>
          {cuerpo}
          {confirmacion}
        </CompactErrorBoundary>
      </BottomSheet>
    );
  }

  return (
    <ModalBase title="Nuevo Pedido" onClose={onClose} maxWidth="max-w-2xl" headerExtra={tipoFacturaToggle}>
      {cuerpo}
      {confirmacion}
    </ModalBase>
  );
});

export default ModalPedido;
