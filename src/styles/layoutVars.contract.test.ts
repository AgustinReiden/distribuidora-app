import { describe, expect, it } from 'vitest'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { getNoticeRoot } from '../components/ui/noticeRoot'

/**
 * Test de CONTRATO de las medidas del layout (WP-40, #765).
 *
 * El alto del header vivia repetido a mano en cinco lugares (`h-16`, `top-16`,
 * `pt-20`, `100dvh-4rem`, `100dvh-5rem`), en rem y en unidades de Tailwind
 * distintas. Ahora todos derivan de `--header-h`, declarada una vez en el
 * `:root` de src/index.css, para que WP-42 la haga responsiva cambiando un solo
 * lugar. Lo que este archivo cuida es eso: que la variable siga declarada con
 * el valor de hoy y que ningun consumidor vuelva a escribir el numero.
 *
 * Asevera estructura (texto de los archivos, no pixeles) a proposito: jsdom no
 * calcula layout, asi que ningun render puede medir el header. Los pixeles los
 * mide la galeria. Es la red minima que autoriza el propio #765.
 */

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const RAIZ = path.resolve(__dirname, '..', '..')

function leer(relativo: string): string {
  return fs.readFileSync(path.join(RAIZ, relativo), 'utf-8')
}

const INDEX_CSS = 'src/index.css'
const APP = 'src/App.tsx'
const TOP_NAVIGATION = 'src/components/layout/TopNavigation.tsx'
const RUTA_ACTIVA = 'src/components/rutaActiva/RutaActivaTransportista.tsx'
const NOTICE_ROOT = 'src/components/ui/noticeRoot.ts'
const GALERIA_NAVEGACION = 'dev/gallery/sections/SeccionNavegacion.tsx'

/**
 * Las reglas de nivel superior de un CSS (las de adentro de un @media quedan
 * dentro del cuerpo de su @media, no como reglas sueltas), sin comentarios.
 * Alcanza con contar llaves: index.css no tiene llaves adentro de strings.
 */
function reglasDeNivelSuperior(css: string): Array<{ selector: string; cuerpo: string }> {
  const texto = css.replace(/\/\*[\s\S]*?\*\//g, '')
  const reglas: Array<{ selector: string; cuerpo: string }> = []
  let profundidad = 0
  let inicioSelector = 0
  let inicioCuerpo = 0
  for (let i = 0; i < texto.length; i++) {
    const c = texto[i]
    if (c === '{') {
      if (profundidad === 0) inicioCuerpo = i + 1
      profundidad++
    } else if (c === '}') {
      profundidad--
      if (profundidad === 0) {
        reglas.push({
          selector: texto.slice(inicioSelector, inicioCuerpo - 1).trim(),
          cuerpo: texto.slice(inicioCuerpo, i),
        })
        inicioSelector = i + 1
      }
    } else if (c === ';' && profundidad === 0) {
      // `@tailwind base;` y compania: no abren bloque.
      inicioSelector = i + 1
    }
  }
  return reglas
}

/** Las custom properties que declaran los `:root` de nivel superior, en orden de cascada. */
function variablesDeRoot(css: string): Map<string, string> {
  const variables = new Map<string, string>()
  for (const { selector, cuerpo } of reglasDeNivelSuperior(css)) {
    if (selector !== ':root') continue
    for (const declaracion of cuerpo.split(';')) {
      const m = /^\s*(--[\w-]+)\s*:\s*([\s\S]+?)\s*$/.exec(declaracion)
      if (m) variables.set(m[1], m[2])
    }
  }
  return variables
}

/** El className literal (entre comillas dobles) de la primera etiqueta `<tag ...>` del archivo. */
function classNameDeEtiqueta(codigo: string, etiqueta: string): string {
  const m = new RegExp(`<${etiqueta}\\b[^>]*?className="([^"]*)"`).exec(codigo)
  if (!m) throw new Error(`no encontre <${etiqueta} className="..."> en el archivo`)
  return m[1]
}

function clases(className: string): string[] {
  return className.split(/\s+/).filter(Boolean)
}

const ROOT = variablesDeRoot(leer(INDEX_CSS))

/**
 * El valor EFECTIVO de una variable de `:root` para un ancho de ventana: recorre
 * las reglas de nivel superior en orden de cascada y aplica los `:root` sueltos
 * y los de adentro de un `@media (min-width: Npx)` que rija para ese ancho. Las
 * dos pesan lo mismo, así que gana la última: si el @media quedara antes del
 * :root base (o un :root posterior repitiera la variable), el alto de
 * escritorio se perdería aunque cada regla, leída sola, siguiera bien.
 */
function valorEfectivo(css: string, variable: string, ancho: number): string | undefined {
  let valor: string | undefined
  for (const { selector, cuerpo } of reglasDeNivelSuperior(css)) {
    if (selector === ':root') {
      valor = variablesDeRoot(`:root{${cuerpo}}`).get(variable) ?? valor
      continue
    }
    const m = /^@media\s*\(\s*min-width:\s*(\d+)px\s*\)$/.exec(selector.replace(/\s+/g, ' '))
    if (m && ancho >= Number(m[1])) valor = variablesDeRoot(cuerpo).get(variable) ?? valor
  }
  return valor
}

describe('medidas del layout: :root de src/index.css', () => {
  it.each([
    [375, '3.5rem'],
    [1023, '3.5rem'],
    [1024, '4rem'],
    [1280, '4rem'],
  ])('a %i px de ancho, --header-h vale %s (56 px debajo de lg, 64 desde lg: WP-42)', (ancho, esperado) => {
    expect(valorEfectivo(leer(INDEX_CSS), '--header-h', ancho)).toBe(esperado)
  })

  it('declara --bottom-inset en 0px, con unidad: la pila de avisos la suma adentro de un calc()', () => {
    expect(ROOT.get('--bottom-inset')).toBe('0px')
  })

  it('toda variable que leen los consumidores esta declarada (un typo en el nombre no falla en ningun otro lado)', () => {
    const usadas = new Set<string>()
    for (const archivo of [APP, TOP_NAVIGATION, RUTA_ACTIVA, NOTICE_ROOT, GALERIA_NAVEGACION]) {
      for (const m of leer(archivo).matchAll(/var\((--[\w-]+)/g)) usadas.add(m[1])
    }

    expect([...usadas]).toContain('--header-h')
    expect([...usadas]).toContain('--bottom-inset')
    for (const nombre of usadas) {
      expect(ROOT.has(nombre), nombre).toBe(true)
    }
  })
})

describe('medidas del layout: los consumidores derivan de --header-h y no repiten el numero', () => {
  it('el <main> de App.tsx arranca a --header-h mas 1rem de aire, no con pt-20', () => {
    const main = clases(classNameDeEtiqueta(leer(APP), 'main'))

    expect(main).toContain('pt-[calc(var(--header-h)+1rem)]')
    expect(main).not.toContain('pt-20')
  })

  it('el <header> de TopNavigation mide --header-h, no h-16', () => {
    const header = clases(classNameDeEtiqueta(leer(TOP_NAVIGATION), 'header'))

    expect(header).toContain('h-[var(--header-h)]')
    expect(header).not.toContain('h-16')
  })

  it('el panel movil de TopNavigation cuelga de --header-h y descuenta lo mismo en su tope, sin top-16', () => {
    const codigo = leer(TOP_NAVIGATION)
    const m = /ref=\{menuRef\}\s*className=\{`([^`]*)`/.exec(codigo)
    expect(m, 'panel movil: <div ref={menuRef} className={`...`}>').not.toBeNull()
    const panel = clases(m![1])

    expect(panel).toContain('top-[var(--header-h)]')
    expect(panel).toContain('max-h-[calc(100dvh-var(--header-h))]')
    expect(panel).not.toContain('top-16')
  })

  it('el menu de usuario de TopNavigation descuenta --header-h mas 1rem, y el archivo ya no escribe 100dvh-4rem ni 100dvh-5rem', () => {
    const codigo = leer(TOP_NAVIGATION)

    expect(codigo).toContain('max-h-[calc(100dvh-var(--header-h)-1rem)]')
    expect(codigo).not.toContain('100dvh-4rem')
    expect(codigo).not.toContain('100dvh-5rem')
  })

  it('el mapa de la ruta activa descuenta el mismo padding-top del <main>, no 100dvh-5rem', () => {
    const codigo = leer(RUTA_ACTIVA)

    expect(codigo).toContain('h-[calc(100dvh-var(--header-h)-1rem)]')
    expect(codigo).not.toContain('100dvh-5rem')
  })

  it('la pila de avisos topea en la ventana menos --header-h, no en 100dvh-4rem', () => {
    // Sobre la clase real de la pila y no sobre el texto del archivo: el
    // comentario de noticeRoot.ts nombra la misma clase y la haría pasar sola.
    const pila = getNoticeRoot()
    expect(pila).not.toBeNull()
    expect(clases(pila?.className ?? '')).toContain('max-h-[calc(100dvh-var(--header-h))]')
    expect(leer(NOTICE_ROOT)).not.toContain('100dvh-4rem')
  })

  it('la pila sube en la ruta activa justo por encima del FAB «centrar»: el inset es su bottom más su alto', () => {
    // RutaActivaTransportista pone --bottom-inset (INSET_AVISOS_MAPA) para que
    // «Sin conexion» y los banners no tapen «Entregar» ni el FAB (#765). Si el
    // FAB se mueve o cambia de alto y el inset no, la pila vuelve a taparlo.
    const codigo = leer(RUTA_ACTIVA)
    const inset = codigo.match(/INSET_AVISOS_MAPA = 'calc\((\d+(?:\.\d+)?)rem \+ env\(safe-area-inset-bottom\)\)'/)
    const fab = codigo.match(/className="fixed right-4 bottom-\[calc\((\d+(?:\.\d+)?)rem\+env\(safe-area-inset-bottom\)\)\][^"]*\bh-(\d+)\b/)
    expect(inset, 'INSET_AVISOS_MAPA con la forma calc(Nrem + env(safe-area-inset-bottom))').not.toBeNull()
    expect(fab, 'el FAB con bottom-[calc(Nrem+env(safe-area-inset-bottom))] y h-N').not.toBeNull()
    const remDelInset = Number(inset?.[1])
    const remDelFab = Number(fab?.[1]) + Number(fab?.[2]) / 4 // h-N de Tailwind = N/4 rem
    expect(remDelInset).toBe(remDelFab)
    expect(codigo).toContain('useBottomInset(pedidosOrdenados.length > 0 ? INSET_AVISOS_MAPA : null)')
  })

  it('el marco de la galeria mide lo mismo que el header, no h-16', () => {
    const marco = clases(classNameDeEtiqueta(leer(GALERIA_NAVEGACION), 'div'))

    expect(marco).toContain('h-[var(--header-h)]')
    expect(marco).not.toContain('h-16')
  })
})

// =============================================================================
// BARRA INFERIOR DEL CELULAR (WP-41, #766)
// =============================================================================

const BARRA_INFERIOR = 'src/components/layout/MobileBottomNav.tsx'

/** Las declaraciones de la regla `selector` adentro del `@media (max-width: Npx)`. */
function variablesEnMediaMax(css: string, ancho: number, selector: string): Map<string, string> | undefined {
  for (const regla of reglasDeNivelSuperior(css)) {
    const m = /^@media\s*\(\s*max-width:\s*(\d+)px\s*\)$/.exec(regla.selector.replace(/\s+/g, ' '))
    if (!m || Number(m[1]) !== ancho) continue
    const interna = reglasDeNivelSuperior(regla.cuerpo).find(r => r.selector === selector)
    if (interna) return variablesDeRoot(`:root{${interna.cuerpo}}`)
  }
  return undefined
}

describe('medidas del layout: la barra inferior del celular reserva su lugar con --bottom-nav-h', () => {
  it('declara --bottom-nav-h en 0px de base, con unidad: el <main> la suma adentro de un calc()', () => {
    expect(ROOT.get('--bottom-nav-h')).toBe('0px')
  })

  it('debajo de lg, con la clase de la barra en <html>, --bottom-nav-h vale el alto de la barra y --bottom-inset lo sigue', () => {
    const vars = variablesEnMediaMax(leer(INDEX_CSS), 1023, 'html.con-barra-inferior')
    expect(vars, '@media (max-width: 1023px) { html.con-barra-inferior { ... } } en index.css').toBeDefined()

    const altoCss = /^calc\((\d+(?:\.\d+)?)rem \+ env\(safe-area-inset-bottom\)\)$/.exec(vars?.get('--bottom-nav-h') ?? '')
    const altoBarra = /\bh-\[calc\((\d+(?:\.\d+)?)rem\+env\(safe-area-inset-bottom\)\)\]/.exec(leer(BARRA_INFERIOR))
    expect(altoCss, '--bottom-nav-h con la forma calc(Nrem + env(safe-area-inset-bottom))').not.toBeNull()
    expect(altoBarra, 'la barra con h-[calc(Nrem+env(safe-area-inset-bottom))]').not.toBeNull()
    // Si la barra crece y la variable no, el final de cada pantalla queda debajo de ella.
    expect(Number(altoCss?.[1])).toBe(Number(altoBarra?.[1]))

    // La pila de avisos sube por encima de la barra.
    expect(vars?.get('--bottom-inset')).toBe('var(--bottom-nav-h)')
  })

  it('la clase que pone la barra en <html> es la que mira index.css', () => {
    expect(leer(BARRA_INFERIOR)).toContain("'con-barra-inferior'")
  })

  it('la barra se oculta desde lg, el mismo corte del @media de index.css', () => {
    expect(clases(classNameDeEtiqueta(leer(BARRA_INFERIOR), 'nav'))).toContain('lg:hidden')
  })

  it('el <main> de App.tsx deja abajo --bottom-nav-h mas 1.5rem, no pb-6 ni --bottom-inset', () => {
    // --bottom-inset no: la ruta activa la sube a 10rem y ahi el <main> no tiene que crecer.
    const main = clases(classNameDeEtiqueta(leer(APP), 'main'))

    expect(main).toContain('pb-[calc(var(--bottom-nav-h)+1.5rem)]')
    expect(main).not.toContain('pb-6')
    expect(main.join(' ')).not.toContain('--bottom-inset')
  })

  it('la barra va en z-30, debajo del panel (z-40), y se monta entre el panel y su overlay para que este la cubra', () => {
    expect(clases(classNameDeEtiqueta(leer(BARRA_INFERIOR), 'nav'))).toContain('z-30')

    const top = leer(TOP_NAVIGATION)
    const barra = top.indexOf('<MobileBottomNav')
    const panel = /ref=\{menuRef\}\s*className=\{`([^`]*)`/.exec(top)
    expect(barra).toBeGreaterThan(-1)
    expect(panel, 'panel movil: <div ref={menuRef} className={`...`}>').not.toBeNull()
    expect(clases(panel![1])).toContain('z-40')
    // Igual z-index (30): el que viene despues en el DOM queda arriba.
    expect(barra).toBeLessThan(top.indexOf('fixed inset-0 bg-black bg-opacity-25 z-30'))
  })

  it('el panel movil de TopNavigation termina donde empieza la barra: debajo de lg su tope descuenta --bottom-nav-h', () => {
    // Si el panel (z-40) llegara al borde de la ventana taparia la barra (z-30)
    // y el segundo toque sobre "Mas" caeria en un item del panel, no en el overlay.
    const m = /ref=\{menuRef\}\s*className=\{`([^`]*)`/.exec(leer(TOP_NAVIGATION))
    expect(m).not.toBeNull()
    const panel = clases(m![1])

    expect(panel).toContain('max-lg:max-h-[calc(100dvh-var(--header-h)-var(--bottom-nav-h))]')
    // El tope de base sigue (desde lg no hay barra y --bottom-nav-h vale 0px de todos modos).
    expect(panel).toContain('max-h-[calc(100dvh-var(--header-h))]')
    // --bottom-nav-h solo se levanta debajo de lg: el mismo corte del max-lg del panel.
    expect(variablesEnMediaMax(leer(INDEX_CSS), 1023, 'html.con-barra-inferior')?.has('--bottom-nav-h')).toBe(true)
  })

  it('los toasts se apoyan encima de la barra: --bottom-nav-h mas 1rem, no bottom-4 ni --bottom-inset', () => {
    // #766 pide que ningún aviso fijo tape un destino de la barra. Los toasts
    // (NotificationContext) no pasan por la pila de noticeRoot; usan
    // --bottom-nav-h y no --bottom-inset porque en la ruta activa ese vale 10rem.
    const m = /function ToastContainer[\s\S]*?className="([^"]*)"/.exec(leer('src/contexts/NotificationContext.tsx'))
    expect(m).not.toBeNull()
    const contenedor = clases(m![1])

    expect(contenedor).toContain('bottom-[calc(1rem+var(--bottom-nav-h))]')
    expect(contenedor).not.toContain('bottom-4')
    expect(m![1]).not.toContain('--bottom-inset')
  })
})

// =============================================================================
// PILA DE TOASTS CON UN BOTTOM SHEET ABIERTO (#852)
// =============================================================================

const NOTIFICATION_CONTEXT = 'src/contexts/NotificationContext.tsx'
const BOTTOM_SHEET = 'src/components/ui/BottomSheet.tsx'
const USE_MEDIA_QUERY = 'src/hooks/state/useMediaQuery.ts'

// El selector va entero: el sheet abierto (Radix pone data-state="open" en el
// panel y el portal cuelga del body) y la pila por su gancho.
const PILA_CON_SHEET_ABIERTO = 'body:has([data-slot="bottom-sheet"][data-state="open"]) [data-slot="avisos"]'
// #899: el formulario de ModalRegistrarPago (un ui/Dialog con forma de sheet) lleva
// data-sheet-movil; la misma regla lo reconoce, en la misma lista de selectores.
const PILA_CON_FORMULARIO_PAGO_ABIERTO = 'body:has([data-sheet-movil][data-state="open"]) [data-slot="avisos"]'
const SELECTOR_PILA_SUBIDA = `${PILA_CON_SHEET_ABIERTO}, ${PILA_CON_FORMULARIO_PAGO_ABIERTO}`

/** Las declaraciones `propiedad: valor` del cuerpo de una regla (todas, no sólo las `--x`). */
function declaracionesDe(cuerpo: string): Map<string, string> {
  const declaraciones = new Map<string, string>()
  for (const declaracion of cuerpo.split(';')) {
    const m = /^\s*([a-z-]+)\s*:\s*([\s\S]+?)\s*$/.exec(declaracion)
    if (m) declaraciones.set(m[1], m[2])
  }
  return declaraciones
}

/** Las declaraciones de la regla `selector` adentro del `@media (max-width: Npx)`, o `undefined`. */
function reglaEnMediaMax(css: string, ancho: number, selector: string): Map<string, string> | undefined {
  const normalizar = (texto: string) => texto.replace(/\s+/g, ' ').trim()
  for (const regla of reglasDeNivelSuperior(css)) {
    const m = /^@media\s*\(\s*max-width:\s*(\d+)px\s*\)$/.exec(normalizar(regla.selector))
    if (!m || Number(m[1]) !== ancho) continue
    const interna = reglasDeNivelSuperior(regla.cuerpo).find(r => normalizar(r.selector) === normalizar(selector))
    if (interna) return declaracionesDe(interna.cuerpo)
  }
  return undefined
}

describe('la pila de toasts sube a la parte de arriba con un bottom sheet abierto en el celular (#852)', () => {
  const cssSinComentarios = leer(INDEX_CSS).replace(/\/\*[\s\S]*?\*\//g, '')

  it('la pila de NotificationContext lleva data-slot="avisos" y el panel del sheet data-slot="bottom-sheet": los dos ganchos que lee index.css', () => {
    const etiqueta = /function ToastContainer[\s\S]*?<div\b([^>]*)>/.exec(leer(NOTIFICATION_CONTEXT))
    expect(etiqueta, '<div ...> de ToastContainer').not.toBeNull()
    expect(etiqueta![1]).toContain('data-slot="avisos"')

    const sheet = leer(BOTTOM_SHEET)
    expect(sheet).toContain('data-slot="bottom-sheet"')
    // El data-state="open" es el que pone Radix; las animaciones del panel lo leen igual.
    expect(sheet).toContain('data-[state=open]:animate-slide-up')
  })

  it('debajo de sm y con el sheet abierto, la pila va arriba: debajo del área segura, a lo ancho, con bottom auto y el más nuevo contra el borde', () => {
    const reglas = reglaEnMediaMax(leer(INDEX_CSS), 639, SELECTOR_PILA_SUBIDA)
    expect(reglas, `@media (max-width: 639px) { ${SELECTOR_PILA_SUBIDA} { ... } } en index.css`).toBeDefined()

    // Debajo del notch/isla, con aire (1rem como el margen lateral).
    expect(reglas?.get('top')).toMatch(/^calc\(env\(safe-area-inset-top\) \+ \d+(?:\.\d+)?rem\)$/)
    // Sin esto la clase bottom-[calc(...)] sigue puesta y la pila se estira a todo el alto.
    expect(reglas?.get('bottom')).toBe('auto')
    // Abajo el último toast del DOM (el más nuevo) queda contra el borde; arriba hay que invertir.
    expect(reglas?.get('flex-direction')).toBe('column-reverse')
    // A lo ancho: sin el max-w-sm de la esquina, con el mismo margen lateral que el right-4 de siempre.
    expect(reglas?.get('max-width')).toBe('none')
    expect(reglas?.get('left')).toBe('1rem')
    expect(reglas?.get('right')).toBe('1rem')
    const contenedor = clases(/function ToastContainer[\s\S]*?className="([^"]*)"/.exec(leer(NOTIFICATION_CONTEXT))![1])
    expect(contenedor).toContain('right-4')
  })

  it('el corte de 639 px es el complemento del sm de Tailwind y el mismo en que el alta pasa a ser sheet', () => {
    // 640 px = `sm:`. CONSULTA_CELULAR (useMediaQuery) decide si el alta es sheet o diálogo.
    expect(leer(USE_MEDIA_QUERY)).toContain("CONSULTA_CELULAR = 'not all and (min-width: 640px)'")
  })

  it('el gancho de la pila sólo aparece en esa regla: desde 640 px, o con el sheet cerrado, queda donde estaba', () => {
    // Una regla suelta (fuera del @media) o una segunda con otro corte sacaría la pila de su esquina.
    expect(cssSinComentarios.match(/data-slot="avisos"/g) ?? []).toHaveLength(2)
    expect(cssSinComentarios).toContain(PILA_CON_SHEET_ABIERTO)
    expect(cssSinComentarios).toContain(PILA_CON_FORMULARIO_PAGO_ABIERTO)
    // Y la clase de base de la pila (abajo, encima de la barra de WP-41) no cambia: la fija el test de arriba.
    const base = /function ToastContainer[\s\S]*?className="([^"]*)"/.exec(leer(NOTIFICATION_CONTEXT))
    expect(clases(base![1])).toContain('bottom-[calc(1rem+var(--bottom-nav-h))]')
  })
})
