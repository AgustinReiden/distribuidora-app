/**
 * PanelFiltrosPedidos — el contenido ÚNICO del panel de filtros de /pedidos
 * (WP-44, #769).
 *
 * Es el mismo componente en los dos envoltorios: el bottom sheet del celular
 * (`ModalFiltrosPedidos`) y el popover de escritorio (`PedidoFilters`). Antes
 * había dos copias del formulario —la fila inline de escritorio y el sheet— que
 * podían desincronizarse; ahora hay una sola y sólo se monta la del envoltorio
 * abierto.
 *
 * Secciones:
 *  - Estado del pedido
 *  - Pago (admin)
 *  - Transportista (admin)
 *  - Cargado por (admin)
 *  - Entregas con salvedad (admin)
 *  - Entrega programada (admin) — segmented Hoy/Mañana + fecha suelta. Sólo en el
 *    sheet del celular (`mostrarEntrega`): en escritorio el mismo control
 *    (`ControlEntregaProgramada`) ya está en la fila de la barra. En celular la
 *    fila también lo tiene, pero el sheet es un modal: Radix deja lo de atrás
 *    inerte y `aria-hidden`, así que quien lo usa ve un solo juego y el sheet
 *    sigue siendo autosuficiente.
 *  - Fecha de carga — Desde / Hasta (antes, el modal aparte `ModalFiltroFecha`)
 *  - Otros — incluir cancelados
 *
 * Comportamiento "en vivo": cada cambio llama a `onFiltrosChange` en el acto; no
 * hay "Aplicar". Las excepciones son las fechas de carga: un rango invertido
 * (#734) no se emite y se avisa hasta que el usuario lo corrija, y una fecha a
 * medio escribir (el año a mitad de tipear) es un borrador que tampoco se emite.
 *
 * `isAdmin` es el único gate de los cinco filtros secundarios, igual que antes.
 */
import React, { useId, useState, type ChangeEvent } from 'react';
import { Truck, User, X } from 'lucide-react';
import { Button } from '../ui/Button';
import { fechaLocalISO } from '../../utils/formatters';
import { cn } from '../../lib/utils';
import {
  OPCIONES_ESTADO,
  OPCIONES_PAGO,
  OPCIONES_SALVEDAD,
  TRANSPORTISTA_SIN_ASIGNAR,
  diaSiguienteISO,
  payloadLimpiarTodo,
  puntaFechaEmitible,
  validarRangoFechas,
  type FiltrosPedidosUI,
  type ParcheFiltrosPedidos,
  type PersonaFiltro,
  type ValorSalvedad,
} from '../../utils/filtrosPedidos';

export interface PanelFiltrosPedidosProps {
  filtros: FiltrosPedidosUI;
  transportistas?: readonly PersonaFiltro[];
  usuarios?: readonly PersonaFiltro[];
  isAdmin: boolean;
  /**
   * ¿Incluir la sección "Entrega programada" (admin)? El bottom sheet del celular
   * la trae (es un modal: la fila de atrás queda inerte); el popover de escritorio
   * no, porque no tapa la fila y dos copias juntas en pantalla confunden. Por
   * defecto sí.
   */
  mostrarEntrega?: boolean;
  onFiltrosChange: (parche: ParcheFiltrosPedidos) => void;
}

// =============================================================================
// HELPERS LOCALES
// =============================================================================

const SECTION_LABEL = 'text-[11px] font-semibold uppercase tracking-[0.08em] text-stone-500 dark:text-stone-400 mb-2';

const SELECT_NATIVE = cn(
  'w-full h-11 sm:h-10 pl-3 pr-9 rounded-lg border text-sm appearance-none',
  'bg-white dark:bg-gray-800 text-stone-800 dark:text-gray-100',
  'border-stone-200 dark:border-gray-700',
  'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
);

const INPUT_FECHA = cn(
  'w-full h-10 px-3 rounded-lg border text-sm',
  'bg-white dark:bg-gray-800 text-stone-800 dark:text-gray-100',
  'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
);

interface SectionProps {
  label: string;
  children: React.ReactNode;
}

function Section({ label, children }: SectionProps) {
  return (
    <div className="py-3 first:pt-0 last:pb-0 border-b border-stone-100 dark:border-gray-700 last:border-b-0">
      <p className={SECTION_LABEL}>{label}</p>
      {children}
    </div>
  );
}

// =============================================================================
// FECHA DE CARGA (Desde / Hasta)
// =============================================================================

interface SeccionFechaCargaProps {
  desde: string | null;
  hasta: string | null;
  onFiltrosChange: (parche: ParcheFiltrosPedidos) => void;
}

/**
 * Desde / Hasta en vivo, como el resto del panel. Guarda un borrador local para
 * poder mostrar un rango invertido SIN emitirlo (#734): mientras "Desde" sea
 * posterior a "Hasta", el filtro vigente no cambia y se avisa por qué. Al
 * corregir cualquiera de las dos puntas se emite el par entero, porque la punta
 * que quedó retenida también tiene que llegar.
 */
function SeccionFechaCarga({ desde, hasta, onFiltrosChange }: SeccionFechaCargaProps) {
  const idDesde = useId();
  const idHasta = useId();
  const idAviso = useId();
  const [borrador, setBorrador] = useState({ desde: desde ?? '', hasta: hasta ?? '' });
  // Si el rango cambia desde afuera (el chip, otro dispositivo del estado), el
  // borrador se vuelve a sincronizar. Es el patrón de "ajustar estado al cambiar
  // una prop" durante el render, sin efecto.
  const [origen, setOrigen] = useState({ desde, hasta });
  if (origen.desde !== desde || origen.hasta !== hasta) {
    setOrigen({ desde, hasta });
    setBorrador({ desde: desde ?? '', hasta: hasta ?? '' });
  }

  const { valido, mensaje } = validarRangoFechas(borrador.desde, borrador.hasta);

  const cambiar = (punta: 'desde' | 'hasta', valor: string) => {
    const nuevo = { ...borrador, [punta]: valor };
    setBorrador(nuevo);
    // Un borrador a medio escribir (el año a mitad de tipear: '0002-…', '0020-…')
    // se guarda pero no se emite: pediría todo el historial con cada dígito.
    const emitible = puntaFechaEmitible(nuevo.desde) && puntaFechaEmitible(nuevo.hasta);
    if (emitible && validarRangoFechas(nuevo.desde, nuevo.hasta).valido) {
      onFiltrosChange({ fechaDesde: nuevo.desde || null, fechaHasta: nuevo.hasta || null });
    }
  };

  const limpiar = () => {
    setBorrador({ desde: '', hasta: '' });
    onFiltrosChange({ fechaDesde: null, fechaHasta: null });
  };

  const hayFecha = Boolean(borrador.desde || borrador.hasta);
  const claseInput = cn(
    INPUT_FECHA,
    valido ? 'border-stone-200 dark:border-gray-700' : 'border-red-400 dark:border-red-500',
  );

  return (
    <Section label="Fecha de carga">
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label htmlFor={idDesde} className="block text-xs font-medium text-stone-600 dark:text-stone-300 mb-1">Desde</label>
          <input
            id={idDesde}
            type="date"
            value={borrador.desde}
            max={borrador.hasta || undefined}
            onChange={(e) => cambiar('desde', e.target.value)}
            aria-invalid={!valido || undefined}
            aria-describedby={!valido ? idAviso : undefined}
            className={claseInput}
          />
        </div>
        <div>
          <label htmlFor={idHasta} className="block text-xs font-medium text-stone-600 dark:text-stone-300 mb-1">Hasta</label>
          <input
            id={idHasta}
            type="date"
            value={borrador.hasta}
            min={borrador.desde || undefined}
            onChange={(e) => cambiar('hasta', e.target.value)}
            aria-invalid={!valido || undefined}
            aria-describedby={!valido ? idAviso : undefined}
            className={claseInput}
          />
        </div>
      </div>
      {mensaje && (
        <p id={idAviso} role="alert" className="mt-2 text-xs text-red-700 dark:text-red-300">
          {mensaje} No se aplicó.
        </p>
      )}
      {hayFecha && (
        <Button type="button" variant="ghost" size="sm" onClick={limpiar} className="mt-2 -ml-2">
          Limpiar fechas de carga
        </Button>
      )}
    </Section>
  );
}

// =============================================================================
// ENTREGA PROGRAMADA (Hoy / Mañana / fecha suelta) — un solo control, dos lugares
// =============================================================================

export interface ControlEntregaProgramadaProps {
  /** La fecha vigente (YYYY-MM-DD) o `null` si no hay filtro de entrega. */
  value: string | null;
  onFiltrosChange: (parche: ParcheFiltrosPedidos) => void;
  /**
   * `fila`: compacto, en la barra junto al buscador (escritorio y celular).
   * `panel`: a ancho completo, como sección del bottom sheet.
   */
  variante: 'fila' | 'panel';
}

/**
 * El segmented Hoy / Mañana más la fecha suelta y su X. Es el MISMO control en la
 * fila de la barra y en la sección del sheet: emiten los mismos parches
 * (`{ fechaEntregaProgramada: hoy | mañana | fecha | null }`), con "Hoy" y
 * "Mañana" calculados en TZ Argentina y el segundo toque sobre el activo apagándolo.
 */
export function ControlEntregaProgramada({ value, onFiltrosChange, variante }: ControlEntregaProgramadaProps) {
  const hoy = fechaLocalISO();
  const manana = diaSiguienteISO(hoy);
  const esHoy = value === hoy;
  const esManana = value === manana;
  const esCustom = Boolean(value) && !esHoy && !esManana;
  const enFila = variante === 'fila';

  const segmento = (activo: boolean) => cn(
    'rounded-md font-medium transition-colors',
    enFila ? 'h-9 sm:h-8 px-3 text-xs' : 'flex-1 h-9 text-sm',
    activo
      ? 'bg-white dark:bg-gray-700 text-blue-700 dark:text-blue-200 shadow-warm'
      : 'text-stone-600 dark:text-stone-300',
  );

  const segmentado = (
    <div
      className={cn(
        'inline-flex items-center p-1 rounded-lg border border-stone-200 dark:border-gray-700 bg-stone-100 dark:bg-gray-800/70',
        !enFila && 'w-full',
      )}
    >
      <button
        type="button"
        aria-pressed={esHoy}
        onClick={() => onFiltrosChange({ fechaEntregaProgramada: esHoy ? null : hoy })}
        className={segmento(esHoy)}
      >
        Hoy
      </button>
      <button
        type="button"
        aria-pressed={esManana}
        onClick={() => onFiltrosChange({ fechaEntregaProgramada: esManana ? null : manana })}
        className={segmento(esManana)}
      >
        Mañana
      </button>
    </div>
  );

  const fecha = (
    <div className={cn('flex items-center gap-2', !enFila && 'w-full')}>
      <input
        type="date"
        aria-label="Fecha de entrega programada"
        value={value || ''}
        onChange={(e) => onFiltrosChange({ fechaEntregaProgramada: e.target.value || null })}
        className={cn(
          enFila ? 'h-10 sm:h-9 px-2 text-xs rounded-lg border' : INPUT_FECHA,
          'bg-white dark:bg-gray-800 text-stone-800 dark:text-gray-100',
          'focus:outline-none focus:ring-2 focus:ring-blue-500/40 focus:border-blue-400',
          !enFila && 'flex-1',
          esCustom
            ? 'bg-blue-50 dark:bg-blue-900/20 border-blue-300 dark:border-blue-700'
            : 'border-stone-200 dark:border-gray-700',
        )}
      />
      {value && (
        <button
          type="button"
          onClick={() => onFiltrosChange({ fechaEntregaProgramada: null })}
          className={cn(
            'inline-flex items-center justify-center rounded-lg text-stone-500 hover:text-rose-600 hover:bg-rose-50 dark:hover:bg-rose-900/15 transition-colors',
            enFila ? 'w-9 h-9 sm:w-8 sm:h-8' : 'w-10 h-10',
          )}
          aria-label="Limpiar filtro de entrega"
        >
          <X className="w-4 h-4" aria-hidden="true" />
        </button>
      )}
    </div>
  );

  if (!enFila) {
    return <div className="space-y-2">{segmentado}{fecha}</div>;
  }
  return (
    <div className="inline-flex flex-wrap items-center gap-2">
      <span className="inline-flex items-center gap-1.5 text-xs text-stone-500 dark:text-stone-400">
        <Truck className="w-4 h-4" aria-hidden="true" />
        <span>Entrega:</span>
      </span>
      {segmentado}
      {fecha}
    </div>
  );
}

// =============================================================================
// PANEL
// =============================================================================

export default function PanelFiltrosPedidos({
  filtros,
  transportistas = [],
  usuarios = [],
  isAdmin,
  mostrarEntrega = true,
  onFiltrosChange,
}: PanelFiltrosPedidosProps): React.ReactElement {
  return (
    <div>
      {/* Estado del pedido */}
      <Section label="Estado del pedido">
        <select
          aria-label="Filtrar por estado del pedido"
          value={filtros.estado}
          onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estado: e.target.value })}
          className={SELECT_NATIVE}
        >
          {OPCIONES_ESTADO.map(o => (
            <option key={o.value} value={o.value}>{o.label}</option>
          ))}
        </select>
      </Section>

      {/* Pago (admin) */}
      {isAdmin && (
        <Section label="Pago">
          <select
            aria-label="Filtrar por estado de pago"
            value={filtros.estadoPago || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ estadoPago: e.target.value })}
            className={SELECT_NATIVE}
          >
            {OPCIONES_PAGO.map(o => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        </Section>
      )}

      {/* Transportista (admin) */}
      {isAdmin && (
        <Section label="Transportista">
          <div className="relative">
            <Truck className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400 pointer-events-none" aria-hidden="true" />
            <select
              aria-label="Filtrar por transportista"
              value={filtros.transportistaId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ transportistaId: e.target.value })}
              className={cn(SELECT_NATIVE, 'pl-9')}
            >
              <option value="todos">Todos los transportistas</option>
              <option value={TRANSPORTISTA_SIN_ASIGNAR}>Sin asignar</option>
              {transportistas.map(t => (
                <option key={t.id} value={t.id}>{t.nombre}</option>
              ))}
            </select>
          </div>
        </Section>
      )}

      {/* Usuario (admin) */}
      {isAdmin && (
        <Section label="Cargado por">
          <div className="relative">
            <User className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-stone-400 pointer-events-none" aria-hidden="true" />
            <select
              aria-label="Filtrar por usuario que cargó el pedido"
              value={filtros.usuarioId || 'todos'}
              onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ usuarioId: e.target.value })}
              className={cn(SELECT_NATIVE, 'pl-9')}
            >
              <option value="todos">Todos los usuarios</option>
              {usuarios.map(u => (
                <option key={u.id} value={u.id}>{u.nombre}</option>
              ))}
            </select>
          </div>
        </Section>
      )}

      {/* Salvedades (admin) */}
      {isAdmin && (
        <Section label="Entregas con salvedad">
          <select
            aria-label="Filtrar por salvedades en entrega"
            value={filtros.conSalvedad || 'todos'}
            onChange={(e: ChangeEvent<HTMLSelectElement>) => onFiltrosChange({ conSalvedad: e.target.value as ValorSalvedad })}
            className={SELECT_NATIVE}
          >
            {OPCIONES_SALVEDAD.map(o => (
              <option key={o.value} value={o.value}>{o.label}</option>
            ))}
          </select>
        </Section>
      )}

      {/* Entrega programada (admin) */}
      {isAdmin && mostrarEntrega && (
        <Section label="Entrega programada">
          <ControlEntregaProgramada
            variante="panel"
            value={filtros.fechaEntregaProgramada ?? null}
            onFiltrosChange={onFiltrosChange}
          />
        </Section>
      )}

      {/* Fecha de carga (todos los roles) */}
      <SeccionFechaCarga
        desde={filtros.fechaDesde ?? null}
        hasta={filtros.fechaHasta ?? null}
        onFiltrosChange={onFiltrosChange}
      />

      {/* Ver cancelados */}
      <Section label="Otros">
        <label className="flex items-center justify-between gap-3 h-11 px-3 rounded-lg border border-stone-200 dark:border-gray-700 cursor-pointer bg-white dark:bg-gray-800">
          {/* Un solo nombre para los dos envoltorios: el sheet ya lo llamaba así (y sus
              tests lo fijan); la fila de escritorio decía "Ver cancelados". */}
          <span className="text-sm text-stone-700 dark:text-gray-200">
            Incluir cancelados
          </span>
          <input
            type="checkbox"
            checked={filtros.verCancelados || false}
            onChange={(e: ChangeEvent<HTMLInputElement>) => onFiltrosChange({ verCancelados: e.target.checked })}
            className="w-5 h-5 rounded border-stone-300 text-blue-600 focus:ring-blue-500"
          />
        </label>
      </Section>
    </div>
  );
}

// =============================================================================
// PIE: "Limpiar todo" + "Listo" (compartido por el sheet y el popover)
// =============================================================================

export interface PieFiltrosPedidosProps {
  activosCount: number;
  onFiltrosChange: (parche: ParcheFiltrosPedidos) => void;
  onListo: () => void;
  /** Tamaño del botón "Listo": `lg` en el sheet del celular, `md` en el popover. */
  tamanoListo?: 'md' | 'lg';
}

/**
 * "Limpiar todo" manda UN parche con los siete filtros del panel y no cierra;
 * "Listo" sólo cierra, porque los cambios ya se aplicaron en vivo.
 */
export function PieFiltrosPedidos({
  activosCount,
  onFiltrosChange,
  onListo,
  tamanoListo = 'lg',
}: PieFiltrosPedidosProps): React.ReactElement {
  return (
    <div className="flex items-center justify-between gap-3">
      <Button
        type="button"
        variant="ghost"
        size={tamanoListo}
        onClick={() => onFiltrosChange(payloadLimpiarTodo())}
        disabled={activosCount === 0}
      >
        Limpiar todo
      </Button>
      <Button type="button" variant="hero" size={tamanoListo} onClick={onListo}>
        Listo
      </Button>
    </div>
  );
}
