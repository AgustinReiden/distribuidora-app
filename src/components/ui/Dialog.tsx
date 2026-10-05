/**
 * Componente Dialog accesible basado en Radix UI
 *
 * Caracteristicas de accesibilidad:
 * - role="dialog" automatico
 * - aria-modal="true"
 * - aria-labelledby vinculado al titulo
 * - aria-describedby vinculado a la descripcion
 * - Focus trapping (el foco no sale del modal)
 * - Cierre con tecla Escape
 * - Devuelve el foco al elemento que abrio el modal al cerrarlo
 */
import * as React from 'react';
import * as DialogPrimitive from '@radix-ui/react-dialog';
import { X } from 'lucide-react';
import { cn } from '../../lib/utils';

// =============================================================================
// PROPS INTERFACES
// =============================================================================

export interface DialogOverlayProps extends React.ComponentPropsWithoutRef<typeof DialogPrimitive.Overlay> {
  className?: string;
}

// Sin `asChild`: el Content lleva dos hijos (`AvisarAlMontar` y `children`) y
// el `Slot` de Radix exige uno solo (con `asChild` tiraría al montar).
export interface DialogContentProps
  extends Omit<React.ComponentPropsWithoutRef<typeof DialogPrimitive.Content>, 'asChild'> {
  className?: string;
  children?: React.ReactNode;
}

export interface DialogHeaderProps extends React.HTMLAttributes<HTMLDivElement> {
  className?: string;
  children?: React.ReactNode;
  onClose?: () => void;
}

export interface DialogFooterProps extends React.HTMLAttributes<HTMLDivElement> {
  className?: string;
}

export interface DialogTitleProps extends React.ComponentPropsWithoutRef<typeof DialogPrimitive.Title> {
  className?: string;
}

export interface DialogDescriptionProps extends React.ComponentPropsWithoutRef<typeof DialogPrimitive.Description> {
  className?: string;
}

export interface DialogBodyProps extends React.HTMLAttributes<HTMLDivElement> {
  className?: string;
  children?: React.ReactNode;
}

// =============================================================================
// COMPONENTS
// =============================================================================

const Dialog = DialogPrimitive.Root;
const DialogTrigger = DialogPrimitive.Trigger;
const DialogPortal = DialogPrimitive.Portal;
const DialogClose = DialogPrimitive.Close;

const DialogOverlay = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Overlay>,
  DialogOverlayProps
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Overlay
    ref={ref}
    className={cn(
      'fixed inset-0 z-50 bg-black/50 data-[state=open]:animate-fade-in data-[state=closed]:animate-fade-out',
      className
    )}
    {...props}
  />
));
DialogOverlay.displayName = DialogPrimitive.Overlay.displayName;

/**
 * No pinta nada: avisa cuando el Content de Radix se monta. Radix lo monta en
 * cada apertura (Presence), mientras que `DialogContent` puede quedar montado
 * entre una y otra si el `Dialog` se controla con `open`. Va como PRIMER hijo
 * para que su layout effect corra antes que el `autoFocus` de un campo del
 * cuerpo y antes que el effect con el que FocusScope mete el foco adentro.
 *
 * Avisa UNA vez por montaje: en desarrollo, StrictMode vuelve a correr el
 * layout effect después del `autoFocus`, y sin el ref guardaría ese campo (que
 * al cerrar ya no existe) en vez del que abrió. StrictMode conserva los refs.
 */
function AvisarAlMontar({ alMontar }: { alMontar: () => void }) {
  const avisado = React.useRef(false);
  React.useLayoutEffect(() => {
    if (avisado.current) return;
    avisado.current = true;
    alMontar();
  }, [alMontar]);
  return null;
}

/**
 * A dónde devolver el foco al cerrar, en orden de preferencia: el que lo tenía
 * al abrir y, si era un ítem de un menú, el trigger de ese menú (y hacia arriba
 * en un submenú). Un DropdownMenu de Radix se cierra al elegir el ítem y sigue
 * montado durante su `animate-fade-out`, así que el que tiene el foco al abrir
 * es el ítem, que al cerrar el diálogo ya no existe. El trigger se saca del
 * `aria-labelledby` del menú, que Radix apunta al id del trigger (el
 * `aria-controls` del trigger no sirve: se borra al cerrar el menú).
 */
function destinosDeRetorno(activo: Element | null): HTMLElement[] {
  const destinos: HTMLElement[] = [];
  let actual = activo;
  while (actual instanceof HTMLElement && actual !== document.body && !destinos.includes(actual)) {
    destinos.push(actual);
    const idTrigger = actual.closest('[role="menu"]')?.getAttribute('aria-labelledby');
    actual = idTrigger ? document.getElementById(idTrigger) : null;
  }
  return destinos;
}

const DialogContent = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Content>,
  DialogContentProps
>(({ className, children, onCloseAutoFocus, ...props }, ref) => {
  // Devolver el foco al que abrió (#800). Radix 1.1.15 lo devuelve al
  // `Dialog.Trigger`, y acá nadie usa Trigger (se abre con `open`): su
  // `onCloseAutoFocus` hace `preventDefault()` + `triggerRef.current?.focus()`
  // con un ref nulo, así que anula la devolución de FocusScope y el foco cae en
  // <body>. Por eso se guarda quién tenía el foco antes de entrar y se lo
  // enfoca al salir. Vive en el primitivo para que lo hereden ModalBase y
  // ModalConfirmacion, que arma Dialog + DialogContent a mano.
  const destinosRef = React.useRef<HTMLElement[]>([]);
  const recordarQuienAbrio = React.useCallback(() => {
    destinosRef.current = destinosDeRetorno(document.activeElement);
  }, []);

  // FocusScope lo dispara en un setTimeout(0) después del desmontaje. Si el
  // consumidor hizo preventDefault, el foco lo maneja él. Si ningún destino
  // sigue en el DOM (o el que abrió era <body>), no se enfoca nada, como hacía
  // Radix; uno que no toma el foco (deshabilitado, no enfocable) cede al
  // siguiente. Y sólo se devuelve si el foco quedó perdido en <body> (estaba
  // adentro y ese nodo se desmontó): si ya está en otro lado —otro diálogo que
  // se abrió en el mismo gesto, con un `autoFocus` que su trap todavía no
  // registró—, se lo respeta; si no, se lo sacaríamos para mandarlo detrás del
  // overlay. Límite conocido: si lo que se abrió en el mismo gesto es un modal
  // hecho a mano, sin trap ni foco inicial, el foco está en <body> —desde acá
  // no hay cómo saber que hay otro overlay encima— y vuelve al que abrió,
  // detrás de ese overlay. Se arregla pasando ese modal a este primitivo, no
  // acá: así se hizo con ModalRegistrarPago desde la Ficha Cliente (#810).
  const devolverFoco = (event: Event) => {
    onCloseAutoFocus?.(event);
    if (event.defaultPrevented) return;
    event.preventDefault();
    const actual = document.activeElement;
    if (actual && actual !== document.body && actual.isConnected) return;
    for (const destino of destinosRef.current) {
      if (!destino.isConnected) continue;
      destino.focus({ preventScroll: true });
      if (document.activeElement === destino) return;
    }
  };

  return (
    <DialogPortal>
      <DialogOverlay />
      <DialogPrimitive.Content
        ref={ref}
        // Radix 1.1.15 no lo pone (esconde el resto con `aria-hidden`); el
        // contrato de un diálogo modal lo pide. Antes de `props`: sobreescribible.
        aria-modal="true"
        className={cn(
          // `w-[calc(100%-2rem)]` y no `w-full`: por debajo de su `max-w-*` (en
          // el celular) deja 16 px a cada lado en vez de ir de borde a borde.
          'fixed left-[50%] top-[50%] z-50 flex flex-col w-[calc(100%-2rem)] max-w-md translate-x-[-50%] translate-y-[-50%] bg-white dark:bg-gray-800 shadow-xl rounded-xl max-h-[90vh] overflow-hidden',
          // `dialog-in` y no `scale-in`: ver el keyframe en tailwind.config.js.
          'data-[state=open]:animate-dialog-in data-[state=closed]:animate-fade-out',
          'focus:outline-none',
          className
        )}
        {...props}
        onCloseAutoFocus={devolverFoco}
      >
        <AvisarAlMontar alMontar={recordarQuienAbrio} />
        {children}
      </DialogPrimitive.Content>
    </DialogPortal>
  );
});
DialogContent.displayName = DialogPrimitive.Content.displayName;

const DialogHeader: React.FC<DialogHeaderProps> = ({ className, children, onClose, ...props }) => (
  <div
    className={cn(
      'flex justify-between items-center p-4 border-b dark:border-gray-700 flex-shrink-0',
      className
    )}
    {...props}
  >
    {children}
    {onClose && (
      <DialogPrimitive.Close asChild>
        <button
          className="p-1 hover:bg-gray-100 dark:hover:bg-gray-700 rounded-lg transition-colors"
          aria-label="Cerrar"
        >
          <X className="w-6 h-6 text-gray-500 dark:text-gray-400" />
        </button>
      </DialogPrimitive.Close>
    )}
  </div>
);
DialogHeader.displayName = 'DialogHeader';

const DialogFooter: React.FC<DialogFooterProps> = ({ className, ...props }) => (
  <div
    className={cn(
      'flex flex-col-reverse sm:flex-row sm:justify-end sm:space-x-2 p-4 border-t dark:border-gray-700 flex-shrink-0',
      className
    )}
    {...props}
  />
);
DialogFooter.displayName = 'DialogFooter';

const DialogTitle = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Title>,
  DialogTitleProps
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Title
    ref={ref}
    className={cn(
      'text-xl font-semibold text-gray-900 dark:text-white',
      className
    )}
    {...props}
  />
));
DialogTitle.displayName = DialogPrimitive.Title.displayName;

const DialogDescription = React.forwardRef<
  React.ElementRef<typeof DialogPrimitive.Description>,
  DialogDescriptionProps
>(({ className, ...props }, ref) => (
  <DialogPrimitive.Description
    ref={ref}
    className={cn('text-sm text-gray-500 dark:text-gray-400', className)}
    {...props}
  />
));
DialogDescription.displayName = DialogPrimitive.Description.displayName;

const DialogBody: React.FC<DialogBodyProps> = ({ className, children, ...props }) => (
  <div
    className={cn('flex-1 overflow-y-auto overscroll-contain', className)}
    {...props}
  >
    {children}
  </div>
);
DialogBody.displayName = 'DialogBody';

export {
  Dialog,
  DialogPortal,
  DialogOverlay,
  DialogClose,
  DialogTrigger,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
  DialogBody
};
