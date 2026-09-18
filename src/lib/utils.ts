import { clsx, type ClassValue } from 'clsx';
import { extendTailwindMerge } from 'tailwind-merge';

// tailwind-merge tiene que ir a la par de la version de Tailwind: la 3.x esta
// hecha para Tailwind 4 y este repo corre Tailwind 3. Con la 3.x, `cn()` se comia
// en silencio un `bg-gradient-to-br` cuando llegaba cualquier otro `bg-*` (el
// nombre v4 es `bg-linear-to-*`, asi que el de v3 caia en el grupo de color de
// fondo). No fallaba nada: el degrade simplemente desaparecia. La 2.6 es el par
// documentado para Tailwind 3. Si algun dia se migra a Tailwind 4, se sube junto.
//
// La extension cubre lo que ni la 2.6 conoce:
//  - `shadow-warm*` son sombras propias (tailwind.config.js). Sin declararlas caen
//    en el grupo de COLOR de sombra y conviven con `shadow-md` en vez de pisarse.
//  - `flex-shrink-*` / `flex-grow-*` son los alias viejos de `shrink-*` / `grow-*`,
//    validos en Tailwind 3 y presentes en el codigo.
const twMerge = extendTailwindMerge({
  extend: {
    classGroups: {
      shadow: [{ shadow: ['warm', 'warm-md', 'warm-lg'] }],
      shrink: [{ 'flex-shrink': ['', '0'] }],
      grow: [{ 'flex-grow': ['', '0'] }],
    },
  },
});

/**
 * Combina clases de Tailwind de forma inteligente
 * Resuelve conflictos entre clases (ej: p-2 y p-4 → p-4)
 */
export function cn(...inputs: ClassValue[]): string {
  return twMerge(clsx(inputs));
}
