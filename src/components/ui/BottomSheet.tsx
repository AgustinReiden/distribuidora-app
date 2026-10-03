/**
 * BottomSheet
 *
 * Sheet (drawer) que sube desde el borde inferior. Pensado para mobile,
 * donde un Dialog centrado se siente menos natural que un sheet.
 *
 * Basado en Radix Dialog (mismo wrapper que ModalBase) pero con styling
 * de panel anclado al bottom + slide-up animation + drag handle visual.
 *
 * Uso típico (en mobile):
 *   <BottomSheet
 *     open={open}
 *     onClose={...}
 *     title="Filtros"
 *     footer={<FooterButtons />}
 *   >
 *     <FilterSections />
 *   </BottomSheet>
 *
 * Notas:
 *  - El drag handle es puramente visual. No implementamos drag-to-dismiss
 *    porque agrega complejidad y no es esencial; tap fuera + Escape cierran.
 *    El tap fuera se puede apagar con `cerrarAlTocarAfuera={false}` (el alta
 *    de pedido: un toque al costado no puede tirar el carrito armado).
 *  - max-h-[85vh] con scroll interno deja el header + drag handle siempre
 *    visibles, y el footer (si existe) sticky abajo.
 *  - El padding-bottom respeta safe-area-inset-bottom (notch iOS).
 *  - Aria ya está cubierto por DialogPrimitive (role="dialog", focus trap,
 *    Escape, etc.).
 *  - Lo que se sumó para el alta de pedido (WP-46, #771) está APAGADO por
 *    defecto, para que los demás consumidores (ModalFiltrosPedidos) queden
 *    como estaban: `comoDialogo` (aria-modal y devolverle el foco al que abrió,
 *    que Radix 1.1.15 no hace porque nadie usa `Dialog.Trigger`; igual que
 *    `DialogContent`, ui/Dialog.tsx, #800) y `ajustarTeclado` (apoyar el sheet
 *    ENCIMA del teclado del celular, ver `useTecladoVirtual`).
 */
import * as React from 'react';
import * as DialogPrimitive from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import { cn } from '../../lib/utils';

export interface BottomSheetProps {
  open: boolean;
  onClose: () => void;
  title: string;
  /** Descripción opcional para accesibilidad y para mostrar bajo el título. */
  description?: string;
  children: React.ReactNode;
  /** Slot sticky en el fondo (típicamente botones "Limpiar" / "Listo"). */
  footer?: React.ReactNode;
  /** Max-height del sheet. Default '85vh'. */
  maxHeight?: string;
  /** Contenido extra en el header: a la derecha del título, a la izquierda de la X (como en ModalBase). */
  headerExtra?: React.ReactNode;
  /**
   * Tocar afuera (el overlay) cierra el sheet. Default `true`. Con `false` se
   * cancelan las tres modalidades de cierre por interacción externa, igual que
   * en ModalBase; Escape y la X siguen cerrando.
   */
  cerrarAlTocarAfuera?: boolean;
  /**
   * Para contenido que trae su propio scroll y su propia barra de abajo (el
   * alta de pedido): el cuerpo pasa a ser una columna flex sin padding que
   * ocupa todo el alto del sheet, y el hijo pone su `flex-1 min-h-0
   * overflow-y-auto`. Con el cuerpo de siempre habría doble scroll y la barra
   * se iría con el contenido. El alto es fijo (el de `maxHeight`) para que el
   * sheet no salte de tamaño mientras el contenido cambia —p. ej. al filtrar
   * una lista—. Igual que en ModalBase, alternarlo con el sheet abierto
   * remonta el cuerpo.
   */
  bodyBare?: boolean;
  /**
   * Se comporta como un diálogo de verdad: `aria-modal="true"` y, al cerrar, el
   * foco vuelve a quien abrió (Radix lo deja en <body>). Default `false`: no
   * cambia nada para quien no lo pide.
   */
  comoDialogo?: boolean;
  /**
   * Con el teclado del celular abierto, apoya el sheet encima del teclado y
   * lo achica al alto que queda visible, para que el footer no quede tapado
   * (iOS y Chrome Android achican sólo el viewport visual y un `fixed;
   * bottom: 0` queda pegado al de layout). Default `false`.
   */
  ajustarTeclado?: boolean;
}

/**
 * Cuánto del fondo de la ventana tapa el teclado virtual, y cuánto alto queda
 * visible arriba de él. En px; `null` sin `visualViewport` (jsdom, navegadores
 * viejos) o sin teclado.
 *
 * El teclado achica el viewport VISUAL y no el de layout (Chrome Android desde
 * la 108, iOS siempre), así que ni `vh` ni `dvh` se enteran. La cuenta es la
 * distancia entre el fondo del viewport visual y el fondo del de layout.
 * Debajo de 1 px es redondeo, no teclado.
 */
interface Teclado {
  tapa: number;
  visible: number;
}

function hayVisualViewport(): boolean {
  return typeof window !== 'undefined' && !!window.visualViewport;
}

function suscribirTeclado(onCambio: () => void): () => void {
  if (!hayVisualViewport()) return () => {};
  const vv = window.visualViewport!;
  vv.addEventListener('resize', onCambio);
  vv.addEventListener('scroll', onCambio);
  return () => {
    vv.removeEventListener('resize', onCambio);
    vv.removeEventListener('scroll', onCambio);
  };
}

// La instantánea es un string para que `useSyncExternalStore` la compare por
// valor: un objeto nuevo en cada lectura lo haría re-renderizar sin fin.
function leerTeclado(): string {
  if (!hayVisualViewport()) return '';
  const vv = window.visualViewport!;
  // Con zoom de dos dedos el viewport visual también se achica, sin teclado.
  // Ahí el sheet tiene que agrandarse con el zoom, no reacomodarse.
  if (typeof vv.scale === 'number' && Math.abs(vv.scale - 1) > 0.01) return '';
  const tapa = Math.round(window.innerHeight - vv.height - vv.offsetTop);
  return tapa > 1 ? `${tapa}|${Math.floor(vv.height)}` : '';
}

const sinTeclado = (): string => '';

const suscribirNada = (): (() => void) => () => {};

/** Con `activo` apagado ni se suscribe: devuelve siempre `null`. */
function useTecladoVirtual(activo: boolean): Teclado | null {
  const instantanea = React.useSyncExternalStore(
    activo ? suscribirTeclado : suscribirNada,
    activo ? leerTeclado : sinTeclado,
    sinTeclado,
  );
  if (!instantanea) return null;
  const [tapa, visible] = instantanea.split('|').map(Number);
  return { tapa, visible };
}

/**
 * No pinta nada: guarda quién tenía el foco cuando el Content se monta (Radix
 * lo monta en cada apertura). Va como primer hijo para correr antes que el
 * `autoFocus` de un campo del cuerpo. Mismo mecanismo que `AvisarAlMontar` de
 * ui/Dialog.tsx.
 */
function RecordarQuienAbrio({ recordar }: { recordar: () => void }) {
  const recordado = React.useRef(false);
  React.useLayoutEffect(() => {
    if (recordado.current) return;
    recordado.current = true;
    recordar();
  }, [recordar]);
  return null;
}

export function BottomSheet({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  maxHeight = '85vh',
  headerExtra,
  cerrarAlTocarAfuera = true,
  bodyBare = false,
  comoDialogo = false,
  ajustarTeclado = false,
}: BottomSheetProps): React.ReactElement {
  const teclado = useTecladoVirtual(ajustarTeclado);
  const contentRef = React.useRef<HTMLDivElement>(null);

  // Con el teclado recién abierto (o cuando cambia su alto), el campo enfocado
  // puede haber quedado debajo: el sheet se achicó y su scroll no se movió.
  // Depende de los números y no del objeto: `useTecladoVirtual` devuelve uno
  // nuevo en cada render, y con él el efecto correría en cada tecla tipeada,
  // devolviendo el scroll al campo enfocado mientras el usuario mira la lista.
  const tapa = teclado?.tapa ?? 0;
  const visible = teclado?.visible ?? 0;
  React.useEffect(() => {
    if (!tapa) return;
    const activo = document.activeElement;
    if (activo instanceof HTMLElement && contentRef.current?.contains(activo)) {
      activo.scrollIntoView?.({ block: 'nearest' });
    }
  }, [tapa, visible]);

  const quienAbrioRef = React.useRef<HTMLElement | null>(null);
  const recordarQuienAbrio = React.useCallback(() => {
    const activo = document.activeElement;
    quienAbrioRef.current = activo instanceof HTMLElement && activo !== document.body ? activo : null;
  }, []);

  // Radix lo dispara después del desmontaje. Sólo se devuelve el foco si quedó
  // perdido en <body>: si ya está en otro lado (otro diálogo que se abrió en el
  // mismo gesto), se lo respeta.
  const devolverFoco = (event: Event) => {
    event.preventDefault();
    const actual = document.activeElement;
    if (actual && actual !== document.body && actual.isConnected) return;
    const destino = quienAbrioRef.current;
    if (destino?.isConnected) destino.focus({ preventScroll: true });
  };

  // Un toque en el overlay. El foco que sale del panel ya lo cancela Radix en el
  // Dialog modal (con o sin esta prop); `onFocusOutside` se pasa igual para que
  // siga cancelado si el sheet dejara de ser modal.
  const bloquearAfuera = (event: Event) => {
    if (!cerrarAlTocarAfuera) event.preventDefault();
  };

  // Con teclado: el sheet se apoya en el borde de arriba del teclado y no pasa
  // del alto que queda visible (8 px de aire arriba para que se lea que es un
  // sheet). El safe-area del fondo deja de aplicar: abajo está el teclado, no
  // el borde de la pantalla.
  const altoMax = teclado ? `${Math.max(teclado.visible - 8, 0)}px` : maxHeight;
  const estiloPanel: React.CSSProperties = {
    maxHeight: altoMax,
    ...(bodyBare ? { height: altoMax } : {}),
    ...(teclado ? { bottom: teclado.tapa } : {}),
  };
  const paddingFondo = teclado ? '0px' : 'env(safe-area-inset-bottom)';

  return (
    <DialogPrimitive.Root open={open} onOpenChange={(v) => !v && onClose()}>
      <DialogPrimitive.Portal>
        {/* Overlay con fade */}
        <DialogPrimitive.Overlay
          className={cn(
            'fixed inset-0 z-50 bg-black/40 backdrop-blur-[2px]',
            'data-[state=open]:animate-fade-in data-[state=closed]:animate-fade-out',
          )}
        />
        {/* Panel anclado al fondo */}
        <DialogPrimitive.Content
          ref={contentRef}
          {...(comoDialogo ? { 'aria-modal': true } : {})}
          // Sin descripción, que no apunte a un id que no existe (y que Radix
          // no avise por consola).
          {...(description ? {} : { 'aria-describedby': undefined })}
          data-slot="bottom-sheet"
          className={cn(
            'fixed bottom-0 left-0 right-0 z-50',
            'flex flex-col',
            'bg-white dark:bg-gray-800',
            'rounded-t-2xl shadow-2xl border-t border-stone-200 dark:border-gray-700',
            'data-[state=open]:animate-slide-up data-[state=closed]:animate-slide-down',
            'focus:outline-none',
          )}
          style={estiloPanel}
          // Con `cerrarAlTocarAfuera` (default) no se cancela nada: el cierre
          // por tap en el overlay es el default de Radix.
          onPointerDownOutside={bloquearAfuera}
          onInteractOutside={bloquearAfuera}
          onFocusOutside={bloquearAfuera}
          {...(comoDialogo ? { onCloseAutoFocus: devolverFoco } : {})}
        >
          {comoDialogo && <RecordarQuienAbrio recordar={recordarQuienAbrio} />}
          {/* Drag handle visual */}
          <div className="flex-shrink-0 pt-2 pb-1 flex items-center justify-center">
            <div
              className="w-10 h-1 rounded-full bg-stone-300 dark:bg-stone-600"
              aria-hidden="true"
            />
          </div>

          {/* Header: título + extra + close */}
          <div className="flex-shrink-0 px-5 pt-1 pb-3 flex items-start justify-between gap-3 border-b border-stone-200 dark:border-gray-700">
            <div className="min-w-0 flex-1">
              <DialogPrimitive.Title className="text-lg font-semibold text-stone-900 dark:text-white leading-tight">
                {title}
              </DialogPrimitive.Title>
              {description && (
                <DialogPrimitive.Description className="text-xs text-stone-500 dark:text-stone-400 mt-0.5">
                  {description}
                </DialogPrimitive.Description>
              )}
            </div>
            {headerExtra && <div className="flex-shrink-0 self-center">{headerExtra}</div>}
            <DialogPrimitive.Close asChild>
              <button
                type="button"
                className="flex-shrink-0 inline-flex items-center justify-center w-8 h-8 rounded-lg text-stone-500 dark:text-stone-400 hover:bg-stone-100 dark:hover:bg-gray-700 transition-colors"
                aria-label="Cerrar"
              >
                <X className="w-5 h-5" aria-hidden="true" />
              </button>
            </DialogPrimitive.Close>
          </div>

          {bodyBare ? (
            // min-h-0 deja que la columna se achique dentro del alto del sheet.
            // El overflow es sólo red: el hijo scrollea solo, pero una pantalla
            // que no se achica (p. ej. el aviso de GPS) igual tiene que poder
            // leerse entera en un celular bajo.
            <div
              className="flex flex-1 min-h-0 flex-col overflow-y-auto overscroll-contain"
              style={{ paddingBottom: paddingFondo }}
            >
              {children}
            </div>
          ) : (
            /* Contenido scrolleable */
            <div className="flex-1 overflow-y-auto overscroll-contain px-5 py-3">
              {children}
            </div>
          )}

          {/* Footer sticky */}
          {footer && (
            <div
              className="flex-shrink-0 px-5 py-3 border-t border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800"
              style={{ paddingBottom: teclado ? '0.75rem' : 'max(0.75rem, env(safe-area-inset-bottom))' }}
            >
              {footer}
            </div>
          )}
        </DialogPrimitive.Content>
      </DialogPrimitive.Portal>
    </DialogPrimitive.Root>
  );
}

export default BottomSheet;
