/**
 * La pila de avisos fijos (#716): un solo `<div id="notice-root">` en `body`
 * donde se apilan, por portal, los tres avisos de estado (`OfflineIndicator`,
 * `BannerActualizacion`, `SyncStatusBanner`).
 *
 * Antes cada uno se anclaba por su cuenta en `bottom-4 right-4`, con z-index
 * distintos, y se tapaban: en el celular "Hay una version nueva" tapaba entero a
 * "operaciones fallaron". Acá la posición la pone la pila y cada aviso sólo se
 * dibuja a sí mismo: `flex-col-reverse` hace que el primero en el DOM quede abajo
 * y los siguientes suban, sin pisarse.
 *
 * Capa de posición pura: sin estado ni contexto. No hay nada que montar: el
 * primer aviso que se renderiza la crea y los demás la reusan.
 *
 *  - `z-40`: la pila va DEBAJO de todo lo que está en `z-50` o más en el
 *    contexto raíz, no sólo de modales y sheets. Eso son los modales de Radix
 *    (`z-50`, portaleados después en el `body`) y los hechos a mano (`z-50`, y
 *    `z-[60]` como `ModalNoEntrega`): un aviso de estado nunca tapa ni se come el
 *    toque de un botón de un modal abierto. Pero también es el header fijo
 *    (`TopNavigation`, `z-50`) con todo lo que cuelga de él —el menú de usuario,
 *    el panel de la campana y el atrapa-clicks transparente `fixed inset-0` que
 *    monta `DbNotificationBell` al abrirse— y los desplegables `z-50` de la
 *    página. Mientras una de esas capas está abierta encima de la pila, un toque
 *    sobre un aviso cierra la capa en vez de accionar el aviso (con la campana
 *    abierta, "Actualizar" no recarga: cierra la campana). Antes
 *    `OfflineIndicator` y `BannerActualizacion` (`z-50`, después del header en el
 *    DOM) quedaban encima de todo eso y sí se accionaban. Es a propósito: subir
 *    la pila por encima de `z-50` es volver a tapar los modales.
 *  - Los toasts NO van acá: tienen que verse encima de un modal (un error al
 *    guardar desde un modal se avisa con un toast), así que siguen en su propio
 *    contenedor `z-[100]` de `NotificationContext`.
 *  - `max-h-[calc(100dvh-4rem)]` (4rem = el header `h-16`) con scroll propio:
 *    sin tope, varios avisos expandidos en un celular se salían por arriba y no
 *    se podían alcanzar. El scroll encadena desde los avisos, que sí reciben el
 *    puntero aunque la pila no.
 *  - `*:shrink-0`: ningún aviso se achica para entrar. Sin esto, un aviso con
 *    `overflow-hidden` (`SyncStatusBanner`) tiene `min-height` 0 como ítem flex
 *    y, cuando la suma pasa el tope, se aplasta en vez de desbordar: la pila
 *    nunca llega a scrollear y "Reintentar" y "Eliminar" quedan recortados, sin
 *    forma de alcanzarlos. Con él la pila desborda y el tope hace su trabajo.
 *  - `pointer-events-none` en la pila, `pointer-events-auto` en cada aviso: la
 *    franja vacía entre avisos no se come los clicks de la pantalla de abajo.
 *  - `[body[style*="pointer-events:_none"]_&>*]:pointer-events-none`: con una
 *    capa modal de Radix abierta, Radix pone `pointer-events: none` en el `body`
 *    para que lo de afuera sea inerte, y lo de afuera lo hereda. El
 *    `pointer-events-auto` explícito de los avisos se escapaba de ese bloqueo:
 *    con el menú de acciones de un pedido abierto (`DropdownMenu` modal y sin
 *    overlay, en `PedidoActions`), tocar "Actualizar" recargaba y "Eliminar"
 *    descartaba las operaciones fallidas, además de cerrar el menú. Esta regla
 *    les devuelve la herencia del `body`: si el `body` está en `none`, los
 *    avisos también, y el toque sólo cierra la capa, como antes de la pila. Le
 *    gana al `pointer-events-auto` del aviso por especificidad, no por orden.
 *  - `left-0` además del `right-0`: sin él la pila mide lo que el aviso más
 *    ancho y el `w-full` de un banner depende del texto que le toque. Con él, en
 *    el celular el banner ocupa el ancho menos 16 px de cada lado, como el viejo
 *    `left-4 right-4`; la pila es transparente y no bloquea nada.
 *  - `padding-bottom` suma `--bottom-inset` a los 16 px de `p-4`: es el gancho
 *    para que algo fijo en el borde de abajo (una barra, un botón de acción)
 *    empuje la pila hacia arriba en vez de quedar tapado. Hoy nadie la define:
 *    vale 0 y los avisos quedan donde estaban (`bottom-4`).
 */

const NOTICE_ROOT_ID = 'notice-root'

const NOTICE_ROOT_CLASSES =
  'fixed left-0 right-0 bottom-0 z-40 flex flex-col-reverse items-end gap-2 p-4 pointer-events-none max-h-[calc(100dvh-4rem)] overflow-y-auto overscroll-contain *:shrink-0 [body[style*="pointer-events:_none"]_&>*]:pointer-events-none'

const NOTICE_ROOT_PADDING_BOTTOM = 'calc(1rem + var(--bottom-inset, 0px))'

/**
 * Devuelve la pila de avisos, creándola la primera vez. Idempotente: la busca por
 * id en cada llamada (no la cachea en el módulo), así que si alguien la sacó del
 * `body` —un test que limpia el DOM— la vuelve a crear en vez de devolver un nodo
 * suelto donde nada se ve.
 *
 * Sin `document` (SSR, un test con entorno `node`) devuelve `null` en vez de
 * tirar: el que llama renderiza el aviso en el lugar, sin portal.
 */
export function getNoticeRoot(): HTMLElement | null {
  if (typeof document === 'undefined' || !document.body) return null

  const existente = document.getElementById(NOTICE_ROOT_ID)
  if (existente) return existente

  const root = document.createElement('div')
  root.id = NOTICE_ROOT_ID
  root.className = NOTICE_ROOT_CLASSES
  root.style.paddingBottom = NOTICE_ROOT_PADDING_BOTTOM
  document.body.appendChild(root)
  return root
}
