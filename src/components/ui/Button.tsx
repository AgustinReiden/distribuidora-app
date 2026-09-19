/**
 * Button — el primitivo de boton de la app.
 *
 * Decisiones que NO son cosmeticas:
 *  - NO fija `type`. Adentro de un `<form>` el navegador asume `submit`, y hay
 *    formularios de la app que dependen de eso (Enter manda). Si el consumidor
 *    pasa `type`, se propaga tal cual.
 *  - `loading` NO implica `disabled`. Pone `aria-busy` y muestra el spinner; si
 *    ademas hay que bloquear el click, el consumidor pasa `disabled`. Hay
 *    botones (cancelar, cerrar) que tienen que seguir andando mientras cargan.
 *  - El spinner es `<Loader2 className="w-4 h-4 animate-spin">`. Esa clase sobre
 *    el `<svg>` es CONTRATO: ModalEditarPedido.test.jsx la busca con
 *    `querySelector('svg.animate-spin')`.
 *
 * Las variantes viven en ./button-variants (regla de eslint
 * `react-refresh/only-export-components`).
 */
import { forwardRef, type ButtonHTMLAttributes, type ReactElement } from 'react'
import { Loader2 } from 'lucide-react'
import { buttonClasses, type ButtonSize, type ButtonVariant } from './button-variants'

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
  /** Muestra el spinner y marca `aria-busy`. No deshabilita el boton. */
  loading?: boolean
}

export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant, size, loading = false, className, children, ...props },
  ref
): ReactElement {
  return (
    <button
      // `aria-busy` va ANTES del spread para que un consumidor que lo maneje a
      // mano pueda pisarlo; `className` y `ref` van despues para que las clases
      // calculadas (con el merge ya resuelto) sean las que quedan.
      aria-busy={loading ? true : undefined}
      {...props}
      ref={ref}
      className={buttonClasses({ variant, size, className })}
    >
      {loading && <Loader2 className="w-4 h-4 animate-spin" aria-hidden="true" />}
      {children}
    </button>
  )
})
