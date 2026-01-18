import { clsx } from 'clsx';
import { twMerge } from 'tailwind-merge';

/**
 * Combina clases de Tailwind de forma inteligente
 * Resuelve conflictos entre clases (ej: p-2 y p-4 → p-4)
 */
export function cn(...inputs) {
  return twMerge(clsx(inputs));
}
