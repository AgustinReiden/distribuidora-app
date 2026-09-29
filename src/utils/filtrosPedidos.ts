/**
 * Lógica pura del panel de filtros de /pedidos (WP-44, #769).
 *
 * Todo lo que la barra de filtros decide sin mirar el DOM vive acá: qué opciones
 * ofrece cada select, qué filtros cuentan como activos para cada rol, qué chip
 * le toca a cada uno y con qué parche se quita, si un rango de fechas es válido
 * y qué manda "Limpiar todo". Los componentes (`PedidoFilters`,
 * `PanelFiltrosPedidos`, `ChipsFiltrosPedidos`) sólo lo pintan.
 *
 * Qué NO hay acá: cómo esos filtros se traducen a la query. Eso es
 * `construirFiltrosPedidos.ts`, y este módulo no lo toca.
 */
import { fechaLocalISO } from './formatters';
import { ESTADO_PAGO_IMPAGO } from './kpiFiltroPedidos';
import { toneDeEstadoPago, toneDeEstadoPedido, type Tone } from '../lib/estadoTones';

// =============================================================================
// TIPOS
// =============================================================================

export type ValorSalvedad = 'todos' | 'con_salvedad' | 'sin_salvedad';

/** Los filtros que la barra lee. Es el subconjunto de `FiltrosPedidosState` que pinta. */
export interface FiltrosPedidosUI {
  estado: string;
  estadoPago?: string;
  transportistaId?: string;
  usuarioId?: string;
  fechaDesde?: string | null;
  fechaHasta?: string | null;
  conSalvedad?: ValorSalvedad;
  verCancelados?: boolean;
  fechaEntregaProgramada?: string | null;
}

/** Lo que la barra emite por `onFiltrosChange`: un parche que el container mergea. */
export type ParcheFiltrosPedidos = Partial<FiltrosPedidosUI>;

/** Una persona que se puede elegir en los selects (transportista o quien cargó). */
export interface PersonaFiltro {
  id: string;
  nombre: string;
}

export interface OpcionFiltro {
  value: string;
  label: string;
}

// =============================================================================
// OPCIONES DE LOS SELECTS
// =============================================================================

/**
 * Los seis estados del select. El `value` es lo que viaja a `pedidos.estado`:
 * "En camino" es 'asignado', que es el que más engaña.
 */
export const OPCIONES_ESTADO: readonly OpcionFiltro[] = [
  { value: 'todos', label: 'Todos los estados' },
  { value: 'pendiente', label: 'Pendientes' },
  { value: 'en_preparacion', label: 'En preparación' },
  { value: 'asignado', label: 'En camino' },
  { value: 'entregado', label: 'Entregados' },
  { value: 'cancelado', label: 'Cancelados' },
];

/**
 * Estados de pago. 'impago' lo aplica el tile "Impagos" de `PedidoStats` (#715):
 * con la opción acá el select lo muestra y lo puede quitar, en vez de caer en
 * "Todos los pagos" con un filtro puesto.
 */
export const OPCIONES_PAGO: readonly OpcionFiltro[] = [
  { value: 'todos', label: 'Todos los pagos' },
  { value: 'pendiente', label: 'Pago pendiente' },
  { value: 'parcial', label: 'Pago parcial' },
  { value: 'pagado', label: 'Pagado' },
  { value: ESTADO_PAGO_IMPAGO, label: 'Impagos (sin pagar o parcial)' },
];

export const OPCIONES_SALVEDAD: readonly OpcionFiltro[] = [
  { value: 'todos', label: 'Todas las entregas' },
  { value: 'con_salvedad', label: 'Con salvedad' },
  { value: 'sin_salvedad', label: 'Sin salvedad' },
];

/** El valor de transportista que filtra los pedidos que todavía no tienen uno. */
export const TRANSPORTISTA_SIN_ASIGNAR = 'sin_asignar';

// Lo que dice el chip, más corto que la opción del select.
const VALOR_CHIP_PAGO: Record<string, string> = {
  pendiente: 'Pendiente',
  parcial: 'Parcial',
  pagado: 'Pagado',
  [ESTADO_PAGO_IMPAGO]: 'Impagos',
};

const VALOR_CHIP_SALVEDAD: Record<string, string> = {
  con_salvedad: 'Con salvedad',
  sin_salvedad: 'Sin salvedad',
};

// =============================================================================
// FECHAS
// =============================================================================

/** El día siguiente a `hoyISO` (YYYY-MM-DD), en TZ Argentina. */
export function diaSiguienteISO(hoyISO: string): string {
  // Mediodía: así el +1 no cruza de día por la diferencia con UTC.
  const d = new Date(hoyISO + 'T12:00:00');
  d.setDate(d.getDate() + 1);
  return fechaLocalISO(d);
}

/** YYYY-MM-DD → DD/MM/AAAA. Si no tiene esa forma, lo devuelve tal cual. */
function fechaCorta(iso: string): string {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(iso);
  return m ? `${m[3]}/${m[2]}/${m[1]}` : iso;
}

export interface ValidacionRango {
  valido: boolean;
  /** Texto para mostrarle al usuario cuando no es válido. */
  mensaje: string | null;
}

export const MENSAJE_RANGO_INVERTIDO = 'La fecha «Desde» es posterior a «Hasta»: así no hay pedidos que mostrar.';

/**
 * Primer año de cuatro dígitos (ver `esFechaCompleta`). No es una regla de negocio:
 * es el corte que separa un año a medio tipear ('0002', '0020', '0202', todos
 * < 1000) de una fecha real. Todo año >= 1000 se emite tal cual, incluidos los
 * anteriores a 2000 que el modal viejo también aplicaba.
 */
export const ANIO_MINIMO_FECHA_CARGA = 1000;

/**
 * ¿Es una fecha YYYY-MM-DD completa y con el año ya tipeado (>= 1000)?
 *
 * Un `input type="date"` con día y mes ya puestos dispara `change` en cada dígito
 * del año que se tipea: '0002-05-01', '0020-05-01', '0202-05-01' y recién después
 * '2026-05-01'. Cada uno es una fecha válida para el navegador pero no es lo que
 * el usuario quiere filtrar: emitirlas pide todo el historial a la base, resetea la
 * página y, con la otra punta puesta, arma un rango invertido pasajero. Lo que no
 * pasa este chequeo es un borrador a medio escribir: ni se emite ni se avisa. Es la
 * única excepción, además del rango invertido, a "el panel emite lo que emitía
 * `ModalFiltroFecha`": una fecha de año < 1000 no la tipea nadie a propósito.
 */
export function esFechaCompleta(valor: string | null | undefined): boolean {
  const m = /^(\d{4})-\d{2}-\d{2}$/.exec(valor ?? '');
  return m !== null && Number(m[1]) >= ANIO_MINIMO_FECHA_CARGA;
}

/**
 * ¿Se puede emitir esta punta del rango? Vacía (rango abierto) o una fecha
 * completa; cualquier otra cosa es un borrador.
 */
export function puntaFechaEmitible(valor: string | null | undefined): boolean {
  return !valor || esFechaCompleta(valor);
}

/**
 * Un rango de fechas de carga es inválido sólo si tiene las dos puntas y
 * "Desde" es posterior a "Hasta" (#734). Media punta o ninguna es válido: es un
 * rango abierto. Las fechas son YYYY-MM-DD, así que se comparan como strings.
 * Una punta a medio escribir (`esFechaCompleta` falso) no cuenta: mientras se
 * tipea el año no hay nada que avisar.
 */
export function validarRangoFechas(
  desde: string | null | undefined,
  hasta: string | null | undefined,
): ValidacionRango {
  if (!puntaFechaEmitible(desde) || !puntaFechaEmitible(hasta)) {
    return { valido: true, mensaje: null };
  }
  if (desde && hasta && desde > hasta) {
    return { valido: false, mensaje: MENSAJE_RANGO_INVERTIDO };
  }
  return { valido: true, mensaje: null };
}

// =============================================================================
// FILTROS ACTIVOS: QUÉ SE VE, QUÉ CUENTA Y CÓMO SE QUITA
// =============================================================================

export type IdChipFiltro =
  | 'estado'
  | 'estadoPago'
  | 'transportistaId'
  | 'usuarioId'
  | 'conSalvedad'
  | 'fechaEntregaProgramada'
  | 'verCancelados'
  | 'fechas';

export interface ChipFiltro {
  id: IdChipFiltro;
  /** Qué filtra: "Estado", "Pago"… */
  etiqueta: string;
  /** El valor puesto, legible: "Pendientes", "Ramón Chofer"… */
  valor: string;
  /** Nombre accesible del botón que lo quita. */
  nombreQuitar: string;
  /** El parche de `onFiltrosChange` que lo quita. */
  quitar: ParcheFiltrosPedidos;
  tone: Tone;
}

export interface ContextoChips {
  isAdmin: boolean;
  transportistas?: readonly PersonaFiltro[];
  usuarios?: readonly PersonaFiltro[];
  /** Hoy en YYYY-MM-DD (TZ Argentina). Se pasa para que la función sea pura. */
  hoy: string;
}

function puesto(valor: string | undefined): valor is string {
  return Boolean(valor) && valor !== 'todos';
}

/**
 * ¿El rol ve el pago puesto? El admin tiene el select; cualquier otro rol sólo
 * puede tenerlo por el tile "Impagos" de `PedidoStats`, que filtra para todos
 * los roles (#715, comentario del dueño en #733): ése tiene que seguir viéndose
 * y contando aunque no haya select, porque el tile es el control visible.
 */
function pagoVisible(estadoPago: string | undefined, isAdmin: boolean): boolean {
  if (!puesto(estadoPago)) return false;
  return isAdmin || estadoPago === ESTADO_PAGO_IMPAGO;
}

function nombreDe(lista: readonly PersonaFiltro[] | undefined, id: string): string {
  return lista?.find(p => String(p.id) === String(id))?.nombre ?? `#${id}`;
}

function etiquetaEntrega(fecha: string, hoy: string): string {
  if (fecha === hoy) return 'Hoy';
  if (fecha === diaSiguienteISO(hoy)) return 'Mañana';
  return fechaCorta(fecha);
}

function chip(
  id: IdChipFiltro,
  etiqueta: string,
  valor: string,
  quitar: ParcheFiltrosPedidos,
  tone: Tone = 'neutral',
): ChipFiltro {
  return { id, etiqueta, valor, nombreQuitar: `Quitar filtro ${etiqueta}`, quitar, tone };
}

/**
 * Los chips de los filtros activos, en el orden del panel.
 *
 * Sólo aparece lo que el rol puede ver (#733): pago, transportista, usuario,
 * salvedad y entrega son de admin, salvo el pago 'impago' del tile, que es de
 * todos. Cada chip trae el parche que lo quita, que es el mismo que emite su
 * control al volver a "Todos".
 *
 * El rango de fechas de carga va último y con su texto y nombre de siempre
 * ("Filtrado: desde – hasta", "Limpiar filtro de fechas"): es el chip que ya
 * existía antes del panel único.
 */
export function chipsFiltrosActivos(filtros: FiltrosPedidosUI, ctx: ContextoChips): ChipFiltro[] {
  const { isAdmin, transportistas, usuarios, hoy } = ctx;
  const chips: ChipFiltro[] = [];

  if (puesto(filtros.estado)) {
    const label = OPCIONES_ESTADO.find(o => o.value === filtros.estado)?.label ?? filtros.estado;
    chips.push(chip('estado', 'Estado', label, { estado: 'todos' }, toneDeEstadoPedido(filtros.estado)));
  }
  if (pagoVisible(filtros.estadoPago, isAdmin)) {
    const pago = filtros.estadoPago as string;
    chips.push(chip('estadoPago', 'Pago', VALOR_CHIP_PAGO[pago] ?? pago, { estadoPago: 'todos' }, toneDeEstadoPago(pago)));
  }
  if (isAdmin && puesto(filtros.transportistaId)) {
    const id = filtros.transportistaId;
    const valor = id === TRANSPORTISTA_SIN_ASIGNAR ? 'Sin asignar' : nombreDe(transportistas, id);
    chips.push(chip('transportistaId', 'Transportista', valor, { transportistaId: 'todos' }));
  }
  if (isAdmin && puesto(filtros.usuarioId)) {
    chips.push(chip('usuarioId', 'Cargado por', nombreDe(usuarios, filtros.usuarioId), { usuarioId: 'todos' }));
  }
  if (isAdmin && puesto(filtros.conSalvedad)) {
    const salvedad = filtros.conSalvedad;
    chips.push(chip(
      'conSalvedad',
      'Salvedad',
      VALOR_CHIP_SALVEDAD[salvedad] ?? salvedad,
      { conSalvedad: 'todos' },
      salvedad === 'con_salvedad' ? 'warning' : 'neutral',
    ));
  }
  if (isAdmin && filtros.fechaEntregaProgramada) {
    chips.push(chip(
      'fechaEntregaProgramada',
      'Entrega',
      etiquetaEntrega(filtros.fechaEntregaProgramada, hoy),
      { fechaEntregaProgramada: null },
      'brand',
    ));
  }
  if (filtros.verCancelados) {
    chips.push(chip('verCancelados', 'Cancelados', 'Incluidos', { verCancelados: false }, 'danger'));
  }
  if (filtros.fechaDesde || filtros.fechaHasta) {
    chips.push({
      id: 'fechas',
      etiqueta: 'Filtrado',
      valor: `${filtros.fechaDesde || '…'} – ${filtros.fechaHasta || '…'}`,
      nombreQuitar: 'Limpiar filtro de fechas',
      quitar: { fechaDesde: null, fechaHasta: null },
      tone: validarRangoFechas(filtros.fechaDesde, filtros.fechaHasta).valido ? 'brand' : 'danger',
    });
  }

  return chips;
}

/**
 * Cuántos filtros activos anuncia el badge del trigger y el subtítulo del panel.
 *
 * No cuenta la búsqueda (tiene su propio campo a la vista) ni el rango de fechas
 * de carga (tiene su chip, y la ventana de 30 días viene puesta por defecto: si
 * contara, el badge nunca estaría en cero). Tampoco lo que el rol no ve (#733),
 * con la excepción del pago 'impago' del tile.
 */
export function contarFiltrosActivos(filtros: FiltrosPedidosUI, { isAdmin }: { isAdmin: boolean }): number {
  let n = 0;
  if (puesto(filtros.estado)) n++;
  if (pagoVisible(filtros.estadoPago, isAdmin)) n++;
  if (isAdmin) {
    if (puesto(filtros.transportistaId)) n++;
    if (puesto(filtros.usuarioId)) n++;
    if (puesto(filtros.conSalvedad)) n++;
    if (filtros.fechaEntregaProgramada) n++;
  }
  if (filtros.verCancelados) n++;
  return n;
}

/** El subtítulo del panel: "Refiná tu búsqueda", "1 filtro activo", "N filtros activos". */
export function describirFiltrosActivos(n: number): string {
  if (n <= 0) return 'Refiná tu búsqueda';
  return n === 1 ? '1 filtro activo' : `${n} filtros activos`;
}

/**
 * El payload de "Limpiar todo": los siete filtros del panel a su valor por
 * defecto, en UN solo parche (un solo reset de página en el container). No toca
 * la búsqueda ni el rango de fechas de carga: la búsqueda vive afuera del panel
 * y el rango tiene su propio "Limpiar".
 */
export function payloadLimpiarTodo(): Required<Pick<
  ParcheFiltrosPedidos,
  'estado' | 'estadoPago' | 'transportistaId' | 'usuarioId' | 'conSalvedad' | 'fechaEntregaProgramada' | 'verCancelados'
>> {
  return {
    estado: 'todos',
    estadoPago: 'todos',
    transportistaId: 'todos',
    usuarioId: 'todos',
    conSalvedad: 'todos',
    fechaEntregaProgramada: null,
    verCancelados: false,
  };
}
