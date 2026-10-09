/**
 * Logo de Crecer Distribuciones.
 *
 *  - `completo` (flecha, CRECER y DISTRIBUCIONES): el login.
 *  - `barra`: la barra de arriba. Flecha + CRECER desde `sm`; en el celular, la
 *    flecha sola. La barra del celular ya no entra con el selector de sucursal,
 *    la campana y el avatar (en 375 px desborda desde antes del logo): la flecha
 *    ocupa lo mismo que el ícono que había, y con CRECER al lado empujaría 30 px
 *    más. Desde `sm` el compacto ocupa menos que el ícono + «Distribuidora» de antes.
 *
 * Las imágenes las genera `scripts/generate-pwa-assets.js` a partir del original
 * (`scripts/marca/`), junto con los íconos de la PWA: no se editan a mano.
 *
 * Cada variante lleva dos <img> y CSS muestra una: el completo, la clara o la
 * oscura («DISTRIBUCIONES» en un verde más claro, porque el original da 2,7:1
 * sobre la tarjeta oscura); la barra, la flecha o el compacto. El modo oscuro de
 * la app es por clase (`.dark` en <html>, ver ThemeContext), no por
 * `prefers-color-scheme`, así que un <picture> con `media` elegiría mal cuando la
 * usuaria lo cambia a mano. Las <img> van con `alt=""` y el nombre en el
 * contenedor, para que haya UN solo nombre accesible (también en jsdom, que no
 * aplica CSS y "ve" las dos).
 *
 * `max-w-none` en las de la barra: el `max-width: 100%` del preflight de Tailwind
 * deja que flex las achique sin mantener la proporción cuando falta lugar.
 */
import type { ReactElement } from 'react'
import { cn } from '../../lib/utils'
import logoClaro from '../../assets/marca/crecer-logo.png'
import logoOscuro from '../../assets/marca/crecer-logo-oscuro.png'
import logoCompacto from '../../assets/marca/crecer-compacto.png'
import logoIsotipo from '../../assets/marca/crecer-isotipo.png'

const NOMBRE_MARCA = 'Crecer Distribuciones'

export interface LogoProps {
  variante: 'completo' | 'barra'
  /** Para el completo, el ancho. La barra trae su alto: el del header. */
  className?: string
}

export function Logo({ variante, className }: LogoProps): ReactElement {
  // width/height son los del archivo: reservan el lugar con la proporción justa
  // antes de que la imagen llegue, así el resto no salta.
  if (variante === 'barra') {
    return (
      <span role="img" aria-label={NOMBRE_MARCA} className={cn('flex shrink-0 items-center', className)}>
        <img src={logoIsotipo} alt="" width={119} height={96} className="h-7 w-auto max-w-none sm:hidden" />
        <img src={logoCompacto} alt="" width={236} height={128} className="hidden h-9 w-auto max-w-none sm:block lg:h-10" />
      </span>
    )
  }

  return (
    <span role="img" aria-label={NOMBRE_MARCA} className={cn('block', className)}>
      <img src={logoClaro} alt="" width={768} height={502} className="block h-auto w-full dark:hidden" />
      <img src={logoOscuro} alt="" width={768} height={502} className="hidden h-auto w-full dark:block" />
    </span>
  )
}
