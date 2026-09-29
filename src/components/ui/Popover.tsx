/**
 * Popover — panel flotante anclado a un trigger, basado en Radix Popover.
 *
 * Para contenido interactivo que no amerita un diálogo centrado: el panel de
 * filtros de /pedidos en escritorio (#769). Radix da gratis lo que a mano hay
 * que reproducir: `role="dialog"` en el contenido, foco adentro al abrir y de
 * vuelta al trigger al cerrar, Escape y click afuera cierran, y `aria-expanded`
 * / `aria-controls` en el trigger.
 *
 * El contenido no tiene nombre accesible propio: el consumidor le pasa
 * `aria-label` o `aria-labelledby` (un `role="dialog"` sin nombre es un hallazgo
 * de accesibilidad).
 *
 * El alto se limita al espacio disponible que mide Radix
 * (`--radix-popover-content-available-height`), así un panel largo scrollea
 * adentro en vez de salirse de la pantalla.
 */
import * as React from 'react';
import * as PopoverPrimitive from '@radix-ui/react-popover';
import { cn } from '../../lib/utils';

const Popover = PopoverPrimitive.Root;
const PopoverTrigger = PopoverPrimitive.Trigger;
const PopoverAnchor = PopoverPrimitive.Anchor;
const PopoverClose = PopoverPrimitive.Close;

export type PopoverContentProps = React.ComponentPropsWithoutRef<typeof PopoverPrimitive.Content>;

const PopoverContent = React.forwardRef<
  React.ElementRef<typeof PopoverPrimitive.Content>,
  PopoverContentProps
>(({ className, align = 'end', sideOffset = 6, collisionPadding = 16, ...props }, ref) => (
  <PopoverPrimitive.Portal>
    <PopoverPrimitive.Content
      ref={ref}
      align={align}
      sideOffset={sideOffset}
      collisionPadding={collisionPadding}
      className={cn(
        'z-50 flex flex-col w-[22rem] max-w-[calc(100vw-2rem)]',
        'max-h-[min(80vh,var(--radix-popover-content-available-height))]',
        'rounded-xl border border-stone-200 dark:border-gray-700 bg-white dark:bg-gray-800 shadow-lg',
        'focus:outline-none',
        'data-[state=open]:animate-scale-in data-[state=closed]:animate-fade-out',
        className,
      )}
      {...props}
    />
  </PopoverPrimitive.Portal>
));
PopoverContent.displayName = 'PopoverContent';

export { Popover, PopoverTrigger, PopoverAnchor, PopoverClose, PopoverContent };
