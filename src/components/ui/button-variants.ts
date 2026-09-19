/**
 * Variantes del primitivo `Button`.
 *
 * Vive en un archivo aparte del componente por `react-refresh/only-export-components`:
 * un archivo que exporta componentes no puede exportar constantes. Aca solo hay
 * constantes y funciones puras.
 *
 * `buttonClasses()` existe ademas del componente para los pocos `<a>` que tienen
 * pinta de boton: se les pasa el string de clases y listo. No hay `asChild` a
 * proposito — eso implicaria sumar `@radix-ui/react-slot`, y dos anchors no lo
 * justifican.
 */
import { cva, type VariantProps } from 'class-variance-authority'
import { cn } from '../../lib/utils'

export const buttonVariants = cva(
  // Base comun a todas las variantes. El foco es visible SIEMPRE (`focus-visible`,
  // no `focus`): un click con mouse no deja el anillo, un Tab si.
  [
    'inline-flex items-center justify-center gap-2 font-medium rounded-lg transition-colors',
    'focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-brand-500 focus-visible:ring-offset-2 dark:focus-visible:ring-offset-gray-900',
    'disabled:opacity-50 disabled:cursor-not-allowed',
  ],
  {
    variants: {
      variant: {
        // `btn-primary` no es una utilidad de Tailwind: es el GANCHO que
        // src/styles/high-contrast.css selecciona con [class*="btn-primary"].
        // Sin el, el primario nuevo se quedaria sin alto contraste, porque esa
        // hoja apunta a `.bg-blue-600` y este primitivo pinta con `brand`.
        // No lo saques "porque no genera CSS": justamente por eso esta.
        primary: 'bg-brand-600 hover:bg-brand-700 text-white btn-primary',
        secondary:
          'bg-white dark:bg-gray-800 border border-gray-300 dark:border-gray-600 text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-700',
        ghost: 'text-gray-600 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-700',
        danger: 'bg-red-600 hover:bg-red-700 text-white',
        // green-700, no green-600: green-600 con texto blanco da 3,30 de
        // contraste y no llega a AA (4,5).
        success: 'bg-green-700 hover:bg-green-800 text-white',
        // El CTA de toolbar. El `transition-[transform,box-shadow]` pisa al
        // `transition-colors` de la base (tailwind-merge resuelve el grupo):
        // sin el, el lift del hover salta de golpe en vez de acompañar.
        hero: 'bg-gradient-to-br from-brand-500 to-brand-700 text-white shadow-warm hover:from-brand-600 hover:to-brand-800 hover:-translate-y-px transition-[transform,box-shadow]',
      },
      size: {
        sm: 'h-8 px-3 text-sm',
        md: 'h-10 px-4 text-sm',
        lg: 'h-11 px-6 text-[14px] font-semibold',
        // Objetivo tactil de 48 px para las vistas de transportista. En un
        // telefono el `hover:` de la variante no se dispara nunca, asi que la
        // devolucion al tocar la da el `active:`.
        touch: 'h-12 px-5 text-base active:opacity-90',
        icon: 'h-10 w-10 p-0',
        iconSm: 'h-8 w-8 p-0',
      },
    },
    defaultVariants: {
      variant: 'primary',
      size: 'md',
    },
  }
)

export type ButtonVariant = NonNullable<VariantProps<typeof buttonVariants>['variant']>
export type ButtonSize = NonNullable<VariantProps<typeof buttonVariants>['size']>

export interface ButtonClassesOptions {
  variant?: ButtonVariant | null
  size?: ButtonSize | null
  className?: string
}

/**
 * String de clases del boton, para lo que no puede ser un `<button>` (los dos
 * `<a>` con estilo de boton). El `className` del consumidor va ULTIMO: asi
 * tailwind-merge lo deja ganar en los conflictos reales y, a la vez, deja
 * sobrevivir lo que no conflictua (un `bg-white` encima de `hero` no se come
 * el `bg-gradient-to-br`, que es de otro grupo).
 */
export function buttonClasses({ variant, size, className }: ButtonClassesOptions = {}): string {
  return cn(buttonVariants({ variant, size }), className)
}
