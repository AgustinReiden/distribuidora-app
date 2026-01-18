/**
 * Modal base reutilizable con accesibilidad completa
 *
 * Usa Radix UI Dialog internamente para:
 * - role="dialog" y aria-modal="true" automáticos
 * - Focus trapping (el foco no sale del modal)
 * - Cierre con tecla Escape
 * - aria-labelledby vinculado al título
 * - Devuelve el foco al elemento que abrió el modal
 */
import React, { memo } from 'react';
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogBody
} from '../ui/Dialog';
import { cn } from '../../lib/utils';

const MAX_WIDTH_MAP = {
  'max-w-sm': 'max-w-sm',
  'max-w-md': 'max-w-md',
  'max-w-lg': 'max-w-lg',
  'max-w-xl': 'max-w-xl',
  'max-w-2xl': 'max-w-2xl',
  'max-w-3xl': 'max-w-3xl',
  'max-w-4xl': 'max-w-4xl',
  'max-w-5xl': 'max-w-5xl',
};

const ModalBase = memo(function ModalBase({
  children,
  onClose,
  title,
  maxWidth = 'max-w-md',
  className
}) {
  return (
    <Dialog open={true} onOpenChange={(open) => !open && onClose()}>
      <DialogContent
        className={cn(MAX_WIDTH_MAP[maxWidth] || maxWidth, className)}
        onPointerDownOutside={(e) => e.preventDefault()}
        onInteractOutside={(e) => e.preventDefault()}
      >
        <DialogHeader onClose={onClose}>
          <DialogTitle>{title}</DialogTitle>
        </DialogHeader>
        <DialogBody>
          {children}
        </DialogBody>
      </DialogContent>
    </Dialog>
  );
});

export default ModalBase;
