import { describe, it, expect } from 'vitest'
import {
  causaDelBloqueo,
  diagnosticoGps,
  entornoDelEquipo,
  instruccionesDesbloqueo,
  pideMotivoSinGps,
} from './ubicacionEquipo'

const UA = {
  chromeAndroid:
    'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36',
  samsung:
    'Mozilla/5.0 (Linux; Android 14; SM-A146M) AppleWebKit/537.36 (KHTML, like Gecko) SamsungBrowser/27.0 Chrome/125.0.0.0 Mobile Safari/537.36',
  safariIphone:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1',
  chromeIphone:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) CriOS/131.0.6778.73 Mobile/15E148 Safari/604.1',
  iphoneStandalone:
    'Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148',
  ipadComoMac:
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15',
  edgeWindows:
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0',
  firefoxAndroid: 'Mozilla/5.0 (Android 13; Mobile; rv:132.0) Gecko/132.0 Firefox/132.0',
}

describe('entornoDelEquipo', () => {
  it('Chrome en Android, pestaña', () => {
    expect(entornoDelEquipo(UA.chromeAndroid)).toEqual({
      so: 'android', soVersion: 10, navegador: 'chrome', navegadorVersion: 131, instalada: false,
    })
  })

  it('Samsung Internet no se confunde con Chrome', () => {
    expect(entornoDelEquipo(UA.samsung, { instalada: true })).toMatchObject({
      so: 'android', soVersion: 14, navegador: 'samsung', navegadorVersion: 27, instalada: true,
    })
  })

  it('Safari y Chrome en iPhone', () => {
    expect(entornoDelEquipo(UA.safariIphone)).toMatchObject({ so: 'ios', soVersion: 17, navegador: 'safari', navegadorVersion: 17 })
    expect(entornoDelEquipo(UA.chromeIphone)).toMatchObject({ so: 'ios', soVersion: 18, navegador: 'chrome', navegadorVersion: 131 })
  })

  it('la app instalada en iPhone (sin "Version/…Safari") es Safari', () => {
    expect(entornoDelEquipo(UA.iphoneStandalone, { instalada: true })).toMatchObject({
      so: 'ios', navegador: 'safari', instalada: true,
    })
  })

  it('un iPad que se presenta como Mac se reconoce por el táctil', () => {
    expect(entornoDelEquipo(UA.ipadComoMac, { maxTouchPoints: 5 }).so).toBe('ios')
    expect(entornoDelEquipo(UA.ipadComoMac, { maxTouchPoints: 0 }).so).toBe('otro')
  })

  it('Edge en Windows y Firefox en Android', () => {
    expect(entornoDelEquipo(UA.edgeWindows)).toMatchObject({ so: 'otro', navegador: 'edge', navegadorVersion: 131 })
    expect(entornoDelEquipo(UA.firefoxAndroid)).toMatchObject({ so: 'android', soVersion: 13, navegador: 'firefox' })
  })

  it('un user agent vacío no rompe', () => {
    expect(entornoDelEquipo('')).toEqual({ so: 'otro', soVersion: null, navegador: 'otro', navegadorVersion: null, instalada: false })
  })
})

describe('causaDelBloqueo', () => {
  it('denied o no se sabe → el sitio; granted o prompt → el teléfono o el navegador', () => {
    expect(causaDelBloqueo('denied')).toBe('sitio')
    expect(causaDelBloqueo('unsupported')).toBe('sitio')
    expect(causaDelBloqueo('granted')).toBe('sistema')
    expect(causaDelBloqueo('prompt')).toBe('sistema')
  })
})

describe('instruccionesDesbloqueo', () => {
  const texto = (pasos: string[]) => pasos.join('\n')
  const androidApp = entornoDelEquipo(UA.chromeAndroid, { instalada: true })
  const androidPestana = entornoDelEquipo(UA.chromeAndroid)
  const iphoneApp = entornoDelEquipo(UA.iphoneStandalone, { instalada: true })
  const iphoneSafari = entornoDelEquipo(UA.safariIphone)

  it('la app instalada en Android no manda a la barra ni al menú de la app: manda a abrir el navegador', () => {
    const pasos = texto(instruccionesDesbloqueo(androidApp, 'sitio'))
    expect(pasos).toMatch(/Abrí Chrome \(el navegador, no la app\)/)
    expect(pasos).not.toMatch(/⋮/)
    expect(pasos).toMatch(/Configuración de sitios/)
  })

  it('la pestaña de Chrome en Android usa el ícono de la dirección y el menú del navegador', () => {
    const pasos = texto(instruccionesDesbloqueo(androidPestana, 'sitio'))
    expect(pasos).toMatch(/izquierda de la dirección/)
    expect(pasos).toMatch(/tres puntos/)
    expect(pasos).not.toMatch(/no la app/)
  })

  it('Samsung Internet se nombra por su nombre', () => {
    const samsung = entornoDelEquipo(UA.samsung, { instalada: true })
    expect(texto(instruccionesDesbloqueo(samsung, 'sitio'))).toMatch(/Abrí Samsung Internet/)
  })

  it('en Android, la causa del sistema manda a la Ubicación del teléfono y al permiso del navegador', () => {
    const pasos = texto(instruccionesDesbloqueo(androidApp, 'sistema'))
    expect(pasos).toMatch(/«Ubicación» esté prendida/)
    expect(pasos).toMatch(/Aplicaciones → Chrome → Permisos → Ubicación/)
    expect(pasos).not.toMatch(/Configuración de sitios/)
  })

  it('en iPhone, la app instalada va por Localización y «Sitios web de Safari»', () => {
    const pasos = texto(instruccionesDesbloqueo(iphoneApp, 'sitio'))
    expect(pasos).toMatch(/Privacidad y seguridad → Localización/)
    expect(pasos).toMatch(/Sitios web de Safari/)
  })

  it('en iPhone con Safari, el sitio bloqueado empieza por la Ubicación de Safari', () => {
    const pasos = instruccionesDesbloqueo(iphoneSafari, 'sitio')
    expect(pasos[0]).toMatch(/«Safari» → Ubicación/)
    expect(texto(instruccionesDesbloqueo(iphoneSafari, 'sistema'))).toMatch(/Localización, y fijate que esté prendida/)
  })

  it('otro equipo: el candado del navegador, o la ubicación del sistema', () => {
    const pc = entornoDelEquipo(UA.edgeWindows)
    expect(texto(instruccionesDesbloqueo(pc, 'sitio'))).toMatch(/configuración de sitios de Edge/)
    expect(texto(instruccionesDesbloqueo(pc, 'sistema'))).toMatch(/ubicación de la computadora/)
  })

  it('todas terminan en reintentar', () => {
    for (const e of [androidApp, androidPestana, iphoneApp, iphoneSafari, entornoDelEquipo('')]) {
      for (const c of ['sitio', 'sistema'] as const) {
        const pasos = instruccionesDesbloqueo(e, c)
        expect(pasos[pasos.length - 1]).toMatch(/Ya lo activé, reintentar/)
      }
    }
  })
})

describe('diagnosticoGps', () => {
  it('familia y versión mayor, nunca el user agent entero', () => {
    const d = diagnosticoGps(entornoDelEquipo(UA.samsung, { instalada: true }), 'granted', 1)
    expect(d).toEqual({ permiso: 'granted', error: 1, instalada: true, navegador: 'samsung 27', so: 'android 14' })
    expect(JSON.stringify(d)).not.toContain('Mozilla')
  })

  it('sin versión, sólo la familia; un error que no es entero va null', () => {
    expect(diagnosticoGps(entornoDelEquipo(''), 'unsupported', null)).toEqual({
      permiso: 'unsupported', error: null, instalada: false, navegador: 'otro', so: 'otro',
    })
    expect(diagnosticoGps(entornoDelEquipo(''), 'prompt', Number.NaN).error).toBeNull()
  })

  it('entra holgado en el tope de 300 bytes de la columna', () => {
    const d = diagnosticoGps(entornoDelEquipo(UA.chromeIphone, { instalada: true }), 'unsupported', 3)
    expect(new TextEncoder().encode(JSON.stringify(d)).length).toBeLessThan(150)
  })
})

describe('pideMotivoSinGps (#1602, decisión a revisar por el dueño)', () => {
  it('todo lo que no es ok pide motivo, también denied', () => {
    expect(pideMotivoSinGps('ok')).toBe(false)
    expect(pideMotivoSinGps('denied')).toBe(true)
    expect(pideMotivoSinGps('timeout')).toBe(true)
    expect(pideMotivoSinGps('unavailable')).toBe(true)
    expect(pideMotivoSinGps('error')).toBe(true)
  })
})
