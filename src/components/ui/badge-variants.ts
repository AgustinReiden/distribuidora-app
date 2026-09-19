import { cva } from 'class-variance-authority';

/**
 * Variantes del Badge. Viven en su propio archivo y no adentro de Badge.tsx
 * porque `react-refresh/only-export-components` (eslint.config.js) no deja que
 * un archivo con componentes exporte tambien constantes.
 *
 * Son DOS cva a proposito, no uno: el consumidor le pasa un `className` al
 * Badge y ese className tiene que poder corregir la forma (margenes, ancho, el
 * radio) pero no el color del tono. Badge.tsx los ordena
 * `cn(badgeFormaVariants(...), className, badgeTonoVariants(...))`, asi que lo
 * de forma queda antes del className (y el consumidor lo puede pisar) y lo de
 * tono queda despues (y no). Un solo cva no permitiria intercalar el className.
 */

/** Forma y tipografia: lo que el consumidor SI puede pisar con su className. */
export const badgeFormaVariants = cva(
  'inline-flex items-center gap-1 rounded-full px-2 py-0.5 text-xs font-semibold whitespace-nowrap',
  {
    variants: {
      // `mono` es para las etiquetas tipo codigo (FC / ZZ / un numero de
      // comprobante): ancho de caracter fijo para que no bailen en una columna,
      // y esquina apenas redondeada en vez de pastilla para que se lean como
      // dato y no como estado.
      mono: {
        true: 'font-mono tracking-wide rounded-[5px]',
        false: '',
      },
    },
    defaultVariants: {
      mono: false,
    },
  }
);

/** Color: lo que el className del consumidor NO puede pisar. */
export const badgeTonoVariants = cva('', {
  variants: {
    tone: {
      neutral: '',
      brand: '',
      success: '',
      warning: '',
      danger: '',
    },
    fill: {
      soft: '',
      strong: '',
    },
  },
  // El color sale del par (tone, fill), asi que va entero en los compuestos.
  // `strong` no lleva `dark:`: es un solido saturado con texto blanco, que se
  // lee igual en los dos temas. `soft` si, porque un 100 sobre fondo oscuro
  // seria un parche claro.
  compoundVariants: [
    {
      tone: 'neutral',
      fill: 'soft',
      class: 'bg-gray-100 text-gray-700 dark:bg-gray-700 dark:text-gray-200',
    },
    {
      tone: 'brand',
      fill: 'soft',
      class: 'bg-brand-100 text-brand-700 dark:bg-brand-900/30 dark:text-brand-300',
    },
    {
      tone: 'success',
      fill: 'soft',
      class: 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300',
    },
    {
      tone: 'warning',
      fill: 'soft',
      class: 'bg-amber-100 text-amber-700 dark:bg-amber-900/30 dark:text-amber-300',
    },
    {
      tone: 'danger',
      fill: 'soft',
      class: 'bg-red-100 text-red-700 dark:bg-red-900/30 dark:text-red-300',
    },
    { tone: 'neutral', fill: 'strong', class: 'bg-gray-600 text-white' },
    { tone: 'brand', fill: 'strong', class: 'bg-brand-600 text-white' },
    { tone: 'success', fill: 'strong', class: 'bg-green-600 text-white' },
    { tone: 'warning', fill: 'strong', class: 'bg-amber-600 text-white' },
    { tone: 'danger', fill: 'strong', class: 'bg-red-600 text-white' },
  ],
  defaultVariants: {
    tone: 'neutral',
    fill: 'soft',
  },
});
