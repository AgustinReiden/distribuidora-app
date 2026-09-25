/**
 * Modal base reutilizable con accesibilidad completa
 *
 * Usa Radix UI Dialog internamente para:
 * - role="dialog" y aria-modal="true" automáticos
 * - Focus trapping (el foco no sale del modal)
 * - Cierre con tecla Escape
 * - aria-labelledby vinculado al título
 * - aria-describedby vinculado a la descripción (accesibilidad)
 * - Devuelve el foco al elemento que abrió el modal
 */
import { memo, ReactNode } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
  DialogBody
} from '../ui/Dialog';
import { CompactErrorBoundary } from '../ErrorBoundary';
import { cn } from '../../lib/utils';

export type ModalMaxWidth =
  | 'max-w-sm'
  | 'max-w-md'
  | 'max-w-lg'
  | 'max-w-xl'
  | 'max-w-2xl'
  | 'max-w-3xl'
  | 'max-w-4xl'
  | 'max-w-5xl'
  | 'max-w-6xl';

export interface ModalBaseProps {
  /** Contenido del modal */
  children: ReactNode;
  /** Callback ejecutado al cerrar el modal */
  onClose: () => void;
  /** Título del modal */
  title: string;
  /** Descripción opcional para accesibilidad */
  description?: string;
  /** Ancho máximo del modal */
  maxWidth?: ModalMaxWidth;
  /** Clases CSS adicionales */
  className?: string;
  /** Contenido adicional en el header (derecha del título, izquierda del botón de cerrar) */
  headerExtra?: ReactNode;
  /**
   * Se pasa tal cual al `DialogContent` de Radix. Un `event.preventDefault()`
   * aborta el cierre por Escape (p. ej. para confirmar antes de descartar
   * cambios sin guardar). Sin la prop, Escape cierra como siempre.
   */
  onEscapeKeyDown?: (event: KeyboardEvent) => void;
  /**
   * Para contenido que ya trae su propio contenedor con scroll y un footer que
   * tiene que quedar siempre visible: el cuerpo pasa a ser una columna flex sin
   * overflow ni padding, y el hijo pone su propio `flex-1 overflow-y-auto`.
   * Con el `DialogBody` de siempre habría doble scroll y el footer se iría con
   * el contenido. Es una decisión fija del modal: alternarla con el modal
   * abierto cambia el contenedor y React remonta el cuerpo (se pierde el estado).
   */
  bodyBare?: boolean;
}

const MAX_WIDTH_MAP: Record<ModalMaxWidth, string> = {
  'max-w-sm': 'max-w-sm',
  'max-w-md': 'max-w-md',
  'max-w-lg': 'max-w-lg',
  'max-w-xl': 'max-w-xl',
  'max-w-2xl': 'max-w-2xl',
  'max-w-3xl': 'max-w-3xl',
  'max-w-4xl': 'max-w-4xl',
  'max-w-5xl': 'max-w-5xl',
  'max-w-6xl': 'max-w-6xl',
};

const ModalBase = memo(function ModalBase({
  children,
  onClose,
  title,
  description,
  maxWidth = 'max-w-md',
  className,
  headerExtra,
  onEscapeKeyDown,
  bodyBare = false
}: ModalBaseProps) {
  // El boundary envuelve sólo el cuerpo (no el header), con o sin `bodyBare`:
  // si algo tira adentro, el modal sigue teniendo título y botón de cerrar.
  const cuerpo = (
    <CompactErrorBoundary componentName={title || 'Modal'} onClose={onClose}>
      {children}
    </CompactErrorBoundary>
  );

  return (
    <Dialog open={true} onOpenChange={(open) => !open && onClose()}>
      <DialogContent
        className={cn(MAX_WIDTH_MAP[maxWidth] || maxWidth, className)}
        // Bloqueo defensivo en TODAS las modalidades de cierre por interacción
        // externa. Radix puede malinterpretar como "outside" cuando el cursor
        // empieza el click DENTRO y se arrastra fuera (selección de texto,
        // drag accidental). preventDefault aborta el cierre — el usuario sigue
        // pudiendo cerrar con Escape o el botón X.
        onPointerDownOutside={(e) => e.preventDefault()}
        onFocusOutside={(e) => e.preventDefault()}
        onInteractOutside={(e) => e.preventDefault()}
        // Detiene la propagación de pointerdown/mousedown del propio contenido
        // hacia los listeners globales del overlay. Sin esto, un click iniciado
        // dentro del modal cuyo `up` cae fuera puede ser interpretado por
        // Radix como interacción externa y disparar el cierre.
        onPointerDown={(e) => e.stopPropagation()}
        onMouseDown={(e) => e.stopPropagation()}
        // undefined cuando no se pasa: Radix cierra con Escape como siempre.
        onEscapeKeyDown={onEscapeKeyDown}
      >
        <DialogHeader onClose={onClose}>
          <div className="flex items-center justify-between flex-1 gap-3 min-w-0">
            <DialogTitle>{title}</DialogTitle>
            {headerExtra && <div className="flex-shrink-0">{headerExtra}</div>}
          </div>
        </DialogHeader>
        {/* DialogDescription para accesibilidad (aria-describedby) - visualmente oculto si no se pasa description */}
        <DialogDescription className={description ? 'px-4 -mt-2 mb-2' : 'sr-only'}>
          {description || `Modal de ${title}`}
        </DialogDescription>
        {bodyBare ? (
          // min-h-0 deja que la columna se achique dentro del max-h-[90vh] del
          // DialogContent; sin él, el `flex-1 overflow-y-auto` del hijo nunca
          // scrollea y el footer se corta abajo.
          <div className="flex flex-1 min-h-0 flex-col">{cuerpo}</div>
        ) : (
          <DialogBody>{cuerpo}</DialogBody>
        )}
      </DialogContent>
    </Dialog>
  );
});

export default ModalBase;
