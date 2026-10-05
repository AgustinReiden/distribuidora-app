/**
 * Barra inferior del celular (WP-41, #766).
 *
 * Es presentacional: qué destinos lleva, si hay "Más" y si se monta lo decide
 * `TopNavigation`, que es donde viven el menú (`menuGroups`), el filtro por rol
 * (`puedeVer`) y el estado del panel desplegable. Así la barra no puede ofrecer
 * nada que el menú no ofrezca, y "Más" abre el MISMO panel que la hamburguesa
 * en vez de duplicarlo.
 *
 * Mientras está montada pone `con-barra-inferior` en `<html>`. Debajo de lg,
 * index.css le da con esa clase su alto a `--bottom-nav-h` (el padding de abajo
 * del `<main>`) y a `--bottom-inset` (la pila de avisos de
 * noticeRoot.ts sube por encima de la barra en vez de taparla). Los toasts de
 * NotificationContext suben con `--bottom-nav-h`. Desde lg la barra está
 * oculta y la clase no hace nada.
 *
 * El alto de la barra es `4rem + env(safe-area-inset-bottom)`, el mismo número
 * que declara index.css: si cambia uno, cambia el otro
 * (src/styles/layoutVars.contract.test.ts los compara).
 */
import React, { useLayoutEffect } from 'react';
import type { Ref } from 'react';
import type { LucideIcon } from 'lucide-react';
import { Ellipsis } from 'lucide-react';

export interface DestinoBarraInferior {
  id: string;
  icon: LucideIcon;
  label: string;
}

export interface MobileBottomNavProps {
  /** Los destinos, en orden. Cada uno navega a `/<id>`. */
  destinos: readonly DestinoBarraInferior[];
  /** La vista actual (el path sin la barra), para marcar `aria-current`. */
  vista: string;
  onNavegar: (id: string) => void;
  /** `null` si todo lo que el menú le ofrece al rol ya está en la barra. */
  mas: {
    abierto: boolean;
    /** Recibe el click: TopNavigation distingue teclado (`detail === 0`) de mouse o toque (#789). */
    onToggle: (event: React.MouseEvent<HTMLButtonElement>) => void;
    /** El listener de click afuera de TopNavigation exceptúa este botón, como la hamburguesa (#730). */
    ref: Ref<HTMLButtonElement>;
    /** El `id` del panel que abre: va en `aria-controls`. */
    controla?: string;
  } | null;
}

const CLASE_EN_HTML = 'con-barra-inferior';

// Cuántas barras hay montadas. En la app hay una sola, pero la galería monta
// varias a la vez: la primera que se desmonta no le puede sacar la clase a las
// otras.
let barrasMontadas = 0;

// text-[11px] y no text-xs: con 5 destinos en 375 px cada columna tiene ~67 px
// útiles, y «Mis entregas» a 12 px se corta (el mockup usa 10,5 px).
const CLASES_ITEM =
  'flex min-h-11 flex-col items-center justify-center gap-0.5 px-1 text-[11px] leading-tight transition-colors focus-visible:ring-inset focus-visible:ring-offset-0';

export default function MobileBottomNav({
  destinos,
  vista,
  onNavegar,
  mas,
}: MobileBottomNavProps): React.ReactElement {
  // Layout y no effect: el padding del <main> y la pila de avisos tienen que
  // subir antes del primer pintado, no un cuadro después con la barra encima.
  useLayoutEffect(() => {
    barrasMontadas++;
    document.documentElement.classList.add(CLASE_EN_HTML);
    return () => {
      barrasMontadas--;
      if (barrasMontadas === 0) document.documentElement.classList.remove(CLASE_EN_HTML);
    };
  }, []);

  return (
    // z-30, debajo del panel del menu (z-40). TopNavigation la monta ANTES del
    // overlay del panel (z-30 tambien), que por venir despues en el DOM la
    // cubre: con el panel abierto la barra queda oscurecida como el resto y un
    // toque sobre ella cierra el panel; para eso el panel termina donde
    // empieza la barra (TopNavigation), si no la taparia entera. Los modales
    // (z-50) y la pila de avisos de noticeRoot (z-40, colgada al final del
    // body) quedan por encima.
    <nav
      aria-label="Navegacion inferior"
      className="fixed inset-x-0 bottom-0 z-30 h-[calc(4rem+env(safe-area-inset-bottom))] pb-[env(safe-area-inset-bottom)] bg-white dark:bg-gray-800 border-t dark:border-gray-700 lg:hidden"
    >
      <div className="grid h-full grid-flow-col auto-cols-[minmax(0,1fr)]">
        {destinos.map(destino => {
          const Icono = destino.icon;
          const activo = vista === destino.id;
          return (
            <button
              key={destino.id}
              type="button"
              onClick={() => onNavegar(destino.id)}
              aria-current={activo ? 'page' : undefined}
              className={`${CLASES_ITEM} ${
                activo
                  ? 'text-blue-700 dark:text-blue-200 font-semibold'
                  : 'text-gray-600 dark:text-gray-300 font-medium hover:bg-gray-100 dark:hover:bg-gray-700/60'
              }`}
            >
              <Icono className="h-5 w-5" aria-hidden="true" />
              <span className="max-w-full truncate">{destino.label}</span>
            </button>
          );
        })}
        {mas && (
          <button
            ref={mas.ref}
            type="button"
            onClick={mas.onToggle}
            aria-expanded={mas.abierto}
            aria-controls={mas.controla}
            className={`${CLASES_ITEM} ${
              mas.abierto
                ? 'text-blue-700 dark:text-blue-200 font-semibold'
                : 'text-gray-600 dark:text-gray-300 font-medium hover:bg-gray-100 dark:hover:bg-gray-700/60'
            }`}
          >
            <Ellipsis className="h-5 w-5" aria-hidden="true" />
            <span className="max-w-full truncate">Más</span>
          </button>
        )}
      </div>
    </nav>
  );
}
