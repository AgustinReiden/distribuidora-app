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
 *  - max-h-[85vh] con scroll interno deja el header + drag handle siempre
 *    visibles, y el footer (si existe) sticky abajo.
 *  - El padding-bottom respeta safe-area-inset-bottom (notch iOS).
 *  - Aria ya está cubierto por DialogPrimitive (role="dialog", focus trap,
 *    Escape, etc.).
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
}

export function BottomSheet({
  open,
  onClose,
  title,
  description,
  children,
  footer,
  maxHeight = '85vh',
}: BottomSheetProps): React.ReactElement {
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
          className={cn(
            'fixed bottom-0 left-0 right-0 z-50',
            'flex flex-col',
            'bg-white dark:bg-gray-800',
            'rounded-t-2xl shadow-2xl border-t border-stone-200 dark:border-gray-700',
            'data-[state=open]:animate-slide-up data-[state=closed]:animate-slide-down',
            'focus:outline-none',
          )}
          style={{ maxHeight }}
          onPointerDownOutside={(e) => {
            // Asegurar cierre por tap en overlay (default de Radix ya lo hace,
            // dejamos pasar el evento).
            void e;
          }}
        >
          {/* Drag handle visual */}
          <div className="flex-shrink-0 pt-2 pb-1 flex items-center justify-center">
            <div
              className="w-10 h-1 rounded-full bg-stone-300 dark:bg-stone-600"
              aria-hidden="true"
            />
          </div>

          {/* Header: título + close */}
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

          {/* Contenido scrolleable */}
          <div className="flex-1 overflow-y-auto overscroll-contain px-5 py-3">
            {children}
          </div>

          {/* Footer sticky */}
          {footer && (
            <div
              className="flex-shrink-0 px-5 py-3 border-t border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800"
              style={{ paddingBottom: 'max(0.75rem, env(safe-area-inset-bottom))' }}
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
