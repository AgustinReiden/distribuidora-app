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

describe('medidas del layout: :root de src/index.css', () => {
  it('declara --header-h en 4rem, el alto del header de hoy (h-16)', () => {
    expect(ROOT.get('--header-h')).toBe('4rem')
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
