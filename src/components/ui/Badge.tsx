import React from 'react';
import type { LucideIcon } from 'lucide-react';
import { cn } from '@/lib/utils';
import type { Tone } from '@/lib/estadoTones';
import { badgeFormaVariants, badgeTonoVariants } from './badge-variants';

export interface BadgeProps extends React.HTMLAttributes<HTMLSpanElement> {
  /** Intencion del color. El mapa estado -> tono vive en `src/lib/estadoTones.ts`. */
  tone?: Tone;
  /** `soft` (pastel, el de siempre) o `strong` (solido, para lo que tiene que gritar). */
  fill?: 'soft' | 'strong';
  /** Icono a la izquierda del texto. Decorativo: va con `aria-hidden`. */
  icon?: LucideIcon;
  /** Etiquetas tipo codigo (FC, ZZ): monoespaciada y con esquina, no pastilla. */
  mono?: boolean;
  className?: string;
  children?: React.ReactNode;
}

/**
 * Etiqueta chica de estado o de dato.
 *
 * Es un `<span>` sin semantica propia: el texto adentro es el que comunica. Si
 * hace falta que un lector de pantalla lo anuncie como otra cosa (un estado que
 * cambia, por ejemplo), eso lo pone el consumidor con `role` / `aria-live`.
 */
export function Badge({
  tone = 'neutral',
  fill = 'soft',
  icon: Icon,
  mono = false,
  className,
  children,
  ...props
}: BadgeProps) {
  return (
    <span
      className={cn(badgeFormaVariants({ mono }), className, badgeTonoVariants({ tone, fill }))}
      {...props}
    >
      {Icon ? <Icon className="h-3 w-3 flex-shrink-0" aria-hidden="true" /> : null}
      {children}
    </span>
  );
}

export default Badge;
