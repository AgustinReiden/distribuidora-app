/**
 * La tabla, única.
 *
 * En el árbol hay 43 `<table>` escritas a mano en 22 archivos, cada una con su
 * `className="w-full text-sm"`, su `<thead>` con el mismo fondo y sus `<td>` con
 * el mismo `px-4 py-3`. Este primitivo es esa tabla una sola vez, partida en los
 * mismos elementos que HTML ya tiene: `Table`, `TableHeader`, `TableBody`,
 * `TableFooter`, `TableRow`, `TableHead`, `TableCell` y `TableCaption`.
 *
 * Acá NO se migra ninguna tabla: eso viene después, archivo por archivo.
 *
 * Decisiones que NO son cosméticas:
 *  - Renderiza los elementos HTML REALES (`table`, `thead`, `tr`, `th`, `td`…),
 *    nunca `div` con `role`. Hay tests que dependen de eso —`.closest('tr')`
 *    sobre una celda en VistaReportesGerenciales.comision y en
 *    ReporteVentasClientes, `getAllByRole('row')` en ReporteStockRed—, y con
 *    `div`s `closest()` devolvería `null` sin que nada lo avise. Por lo mismo
 *    NO escribe `role="table"`: un `<table>` ya es `table`, y el atributo
 *    redundante es justo lo que hoy se repite a mano en cuatro archivos.
 *  - `Table` va envuelta en un contenedor con `overflow-x-auto`: una tabla
 *    ancha se scrollea adentro de su marco en vez de ensanchar la página. Si
 *    se le pasa `etiqueta`, ese contenedor pasa a ser una región con nombre y
 *    foco (`role="region"`, `aria-label`, `tabIndex={0}`): un contenedor que
 *    scrollea y no se puede enfocar deja a quien navega con teclado sin
 *    manera de ver las columnas de la derecha. Sin `etiqueta` no se agrega
 *    nada: una región enfocable SIN nombre es peor que ninguna.
 *  - `TableHead` trae `scope="col"` por defecto (un `<th>` sin `scope` queda a
 *    criterio del lector de pantalla). Una cabecera de FILA lo pisa con
 *    `scope="row"`.
 *  - La variante `numerico` (en `TableHead` y en `TableCell`) alinea a la
 *    derecha con `tabular-nums` y sin cortes de línea: en una columna de montos
 *    los dígitos tienen que quedar uno bajo el otro.
 *  - `ref` y el resto de los atributos van al elemento; `className` se combina
 *    con `cn()`, así que el del consumidor pisa al por defecto (un `py-2` en
 *    las filas de detalle, un `text-center` en una columna).
 *
 * Los colores usan los nombres `gray-*` y no `stone-*` a propósito: en
 * `tailwind.config.js` `gray` tiene los valores de `stone` (#699), así que se
 * ven igual, y `high-contrast.css` apunta a los nombres `gray-*`. Es lo mismo
 * que hacen `Card` y `Badge`.
 */
import {
  createContext,
  forwardRef,
  useContext,
  type ComponentPropsWithoutRef,
  type ReactElement,
} from 'react';
import { cn } from '../../lib/utils';

/*
 * Dónde está una fila. El hover sólo tiene sentido en el cuerpo: una fila de
 * encabezado o de pie que se ilumina al pasar el mouse parece clickeable y no
 * lo es. Un contexto y no un selector CSS (`[&>tr]:hover…`) porque el selector
 * ganaría por especificidad y el consumidor no podría apagarlo con su
 * `className`.
 */
type SeccionDeTabla = 'encabezado' | 'cuerpo' | 'pie';

const SeccionContext = createContext<SeccionDeTabla>('cuerpo');

/** El mismo marco que `Card` (variante `section`), sin su padding. */
const MARCO =
  'bg-white dark:bg-gray-800 rounded-xl border border-gray-200 dark:border-gray-700 shadow-warm';

// -----------------------------------------------------------------------------
// Table
// -----------------------------------------------------------------------------

export interface TableProps extends ComponentPropsWithoutRef<'table'> {
  /**
   * Nombre de la región que scrollea. Si está, el contenedor se vuelve una
   * región enfocable (`role="region"`, `aria-label`, `tabIndex={0}`) para que
   * una tabla ancha se pueda recorrer con el teclado. Si falta, el contenedor
   * sigue scrolleando pero no se anuncia ni toma foco.
   */
  etiqueta?: string;
  /** Clases del contenedor (el `div` que scrollea), no de la `<table>`. */
  contenedorClassName?: string;
  /**
   * Dibuja el marco (fondo, borde, esquinas y sombra de `Card`). `false` para
   * una tabla que ya vive adentro de otra superficie: un modal, una `Card`.
   */
  marco?: boolean;
}

export const Table = forwardRef<HTMLTableElement, TableProps>(function Table(
  { etiqueta, contenedorClassName, marco = true, className, ...resto },
  ref,
): ReactElement {
  const region = etiqueta
    ? ({ role: 'region', 'aria-label': etiqueta, tabIndex: 0 } as const)
    : undefined;

  return (
    <div className={cn('overflow-x-auto', marco && MARCO, contenedorClassName)} {...region}>
      <table ref={ref} className={cn('w-full text-sm', className)} {...resto} />
    </div>
  );
});

// -----------------------------------------------------------------------------
// Secciones: thead / tbody / tfoot
// -----------------------------------------------------------------------------

export type TableHeaderProps = ComponentPropsWithoutRef<'thead'>;

export const TableHeader = forwardRef<HTMLTableSectionElement, TableHeaderProps>(
  function TableHeader({ className, ...resto }, ref): ReactElement {
    return (
      <SeccionContext.Provider value="encabezado">
        <thead
          ref={ref}
          className={cn(
            'bg-gray-50 dark:bg-gray-700/50 border-b border-gray-200 dark:border-gray-700',
            className,
          )}
          {...resto}
        />
      </SeccionContext.Provider>
    );
  },
);

export type TableBodyProps = ComponentPropsWithoutRef<'tbody'>;

export const TableBody = forwardRef<HTMLTableSectionElement, TableBodyProps>(
  function TableBody({ className, ...resto }, ref): ReactElement {
    return (
      <SeccionContext.Provider value="cuerpo">
        <tbody
          ref={ref}
          className={cn('divide-y divide-gray-200 dark:divide-gray-700', className)}
          {...resto}
        />
      </SeccionContext.Provider>
    );
  },
);

export type TableFooterProps = ComponentPropsWithoutRef<'tfoot'>;

export const TableFooter = forwardRef<HTMLTableSectionElement, TableFooterProps>(
  function TableFooter({ className, ...resto }, ref): ReactElement {
    return (
      <SeccionContext.Provider value="pie">
        <tfoot
          ref={ref}
          className={cn(
            'bg-gray-50 dark:bg-gray-700/50 border-t border-gray-200 dark:border-gray-700 font-semibold',
            className,
          )}
          {...resto}
        />
      </SeccionContext.Provider>
    );
  },
);

// -----------------------------------------------------------------------------
// Fila
// -----------------------------------------------------------------------------

export type TableRowProps = ComponentPropsWithoutRef<'tr'>;

export const TableRow = forwardRef<HTMLTableRowElement, TableRowProps>(function TableRow(
  { className, ...resto },
  ref,
): ReactElement {
  const seccion = useContext(SeccionContext);

  return (
    <tr
      ref={ref}
      className={cn(
        seccion === 'cuerpo' && 'transition-colors hover:bg-gray-50 dark:hover:bg-gray-700/40',
        className,
      )}
      {...resto}
    />
  );
});

// -----------------------------------------------------------------------------
// Celdas
// -----------------------------------------------------------------------------

/** Columnas de montos y cantidades: a la derecha, dígitos alineados, sin cortes. */
const NUMERICO = 'text-right tabular-nums whitespace-nowrap';

export interface TableHeadProps extends ComponentPropsWithoutRef<'th'> {
  /** Columna de números: alinea a la derecha con `tabular-nums`. */
  numerico?: boolean;
}

export const TableHead = forwardRef<HTMLTableCellElement, TableHeadProps>(function TableHead(
  { numerico = false, scope = 'col', className, ...resto },
  ref,
): ReactElement {
  return (
    <th
      ref={ref}
      scope={scope}
      className={cn(
        'px-4 py-3 text-xs font-semibold uppercase tracking-wider whitespace-nowrap',
        'text-gray-600 dark:text-gray-300',
        numerico ? NUMERICO : 'text-left',
        className,
      )}
      {...resto}
    />
  );
});

export interface TableCellProps extends ComponentPropsWithoutRef<'td'> {
  /** Celda de un número: alinea a la derecha con `tabular-nums`. */
  numerico?: boolean;
}

export const TableCell = forwardRef<HTMLTableCellElement, TableCellProps>(function TableCell(
  { numerico = false, className, ...resto },
  ref,
): ReactElement {
  return (
    <td
      ref={ref}
      className={cn(
        'px-4 py-3 align-middle text-gray-800 dark:text-gray-100',
        numerico && NUMERICO,
        className,
      )}
      {...resto}
    />
  );
});

// -----------------------------------------------------------------------------
// Caption
// -----------------------------------------------------------------------------

export interface TableCaptionProps extends ComponentPropsWithoutRef<'caption'> {
  /**
   * Oculta el título a la vista pero lo deja como nombre accesible de la tabla.
   * Sirve cuando la vista ya tiene un título visible arriba.
   */
  srOnly?: boolean;
}

export const TableCaption = forwardRef<HTMLTableCaptionElement, TableCaptionProps>(
  function TableCaption({ srOnly = false, className, ...resto }, ref): ReactElement {
    return (
      <caption
        ref={ref}
        className={cn(
          srOnly
            ? 'sr-only'
            : 'px-4 py-3 text-left text-sm font-medium text-gray-600 dark:text-gray-300',
          className,
        )}
        {...resto}
      />
    );
  },
);

export default Table;
