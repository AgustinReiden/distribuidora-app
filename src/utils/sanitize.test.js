/**
 * Tests para utilidades de sanitización
 */
import { describe, it, expect } from 'vitest'
import {
  sanitizeHTML,
  sanitizeText,
  sanitizeRichContent,
  sanitizeURL,
  sanitizeURLParam,
  sanitizeObject,
  sanitizeFormData,
  escapeRegex,
  truncateText
} from './sanitize'

describe('sanitizeText', () => {
  it('debe remover todas las etiquetas HTML', () => {
    expect(sanitizeText('<script>alert("xss")</script>Hello')).toBe('Hello')
    expect(sanitizeText('<b>Bold</b> text')).toBe('Bold text')
    expect(sanitizeText('<div onclick="hack()">Click me</div>')).toBe('Click me')
  })

  it('debe manejar null y undefined', () => {
    expect(sanitizeText(null)).toBe('')
    expect(sanitizeText(undefined)).toBe('')
  })

  it('debe convertir números a string', () => {
    expect(sanitizeText(123)).toBe('123')
    expect(sanitizeText(0)).toBe('0')
  })

  it('debe manejar strings vacíos', () => {
    expect(sanitizeText('')).toBe('')
    expect(sanitizeText('   ')).toBe('   ')
  })
})

describe('sanitizeHTML', () => {
  it('debe permitir etiquetas básicas', () => {
    expect(sanitizeHTML('<b>Bold</b>')).toBe('<b>Bold</b>')
    expect(sanitizeHTML('<i>Italic</i>')).toBe('<i>Italic</i>')
    expect(sanitizeHTML('<strong>Strong</strong>')).toBe('<strong>Strong</strong>')
  })

  it('debe remover etiquetas peligrosas', () => {
    expect(sanitizeHTML('<script>alert("xss")</script>')).toBe('')
    expect(sanitizeHTML('<img src="x" onerror="hack()">')).toBe('')
    expect(sanitizeHTML('<iframe src="evil.com"></iframe>')).toBe('')
  })

  it('debe remover event handlers', () => {
    expect(sanitizeHTML('<div onclick="hack()">Click</div>')).toBe('Click')
    expect(sanitizeHTML('<p onmouseover="steal()">Hover</p>')).toBe('<p>Hover</p>')
  })

  it('debe manejar null y undefined', () => {
    expect(sanitizeHTML(null)).toBe('')
    expect(sanitizeHTML(undefined)).toBe('')
  })
})

describe('sanitizeRichContent', () => {
  it('debe permitir más etiquetas para contenido rico', () => {
    expect(sanitizeRichContent('<h1>Title</h1>')).toBe('<h1>Title</h1>')
    expect(sanitizeRichContent('<ul><li>Item</li></ul>')).toBe('<ul><li>Item</li></ul>')
    expect(sanitizeRichContent('<blockquote>Quote</blockquote>')).toBe('<blockquote>Quote</blockquote>')
  })

  it('debe permitir links con href', () => {
    const result = sanitizeRichContent('<a href="https://example.com">Link</a>')
    expect(result).toContain('href="https://example.com"')
    expect(result).toContain('>Link</a>')
  })

  it('debe remover etiquetas peligrosas', () => {
    expect(sanitizeRichContent('<script>hack()</script>')).toBe('')
    expect(sanitizeRichContent('<object data="evil"></object>')).toBe('')
  })
})

describe('sanitizeURL', () => {
  it('debe aceptar URLs válidas con protocolos permitidos', () => {
    expect(sanitizeURL('https://example.com')).toBe('https://example.com/')
    expect(sanitizeURL('http://example.com/path')).toBe('http://example.com/path')
    expect(sanitizeURL('mailto:test@example.com')).toBe('mailto:test@example.com')
  })

  it('debe rechazar URLs con protocolos no permitidos', () => {
    expect(sanitizeURL('javascript:alert(1)')).toBe(null)
    expect(sanitizeURL('data:text/html,<script>hack()</script>')).toBe(null)
    expect(sanitizeURL('file:///etc/passwd')).toBe(null)
  })

  it('debe permitir rutas relativas válidas', () => {
    expect(sanitizeURL('/path/to/page')).toBe('/path/to/page')
    expect(sanitizeURL('/api/data')).toBe('/api/data')
  })

  it('debe rechazar rutas relativas sospechosas', () => {
    expect(sanitizeURL('//evil.com/path')).toBe(null)
  })

  it('debe manejar null y undefined', () => {
    expect(sanitizeURL(null)).toBe(null)
    expect(sanitizeURL(undefined)).toBe(null)
    expect(sanitizeURL('')).toBe(null)
  })
})

describe('sanitizeURLParam', () => {
  it('debe codificar caracteres especiales', () => {
    expect(sanitizeURLParam('hello world')).toBe('hello%20world')
    expect(sanitizeURLParam('test&value=1')).toBe('test%26value%3D1')
  })

  it('debe remover HTML antes de codificar', () => {
    expect(sanitizeURLParam('<script>hack()</script>')).toBe('')
    expect(sanitizeURLParam('text<b>bold</b>')).toBe('textbold')
  })

  it('debe manejar null y undefined', () => {
    expect(sanitizeURLParam(null)).toBe('')
    expect(sanitizeURLParam(undefined)).toBe('')
  })
})

describe('sanitizeObject', () => {
  it('debe sanitizar todos los strings en un objeto', () => {
    const dirty = {
      name: '<script>hack()</script>John',
      age: 25,
      active: true
    }
    const clean = sanitizeObject(dirty)
    expect(clean.name).toBe('John')
    expect(clean.age).toBe(25)
    expect(clean.active).toBe(true)
  })

  it('debe sanitizar objetos anidados', () => {
    const dirty = {
      user: {
        name: '<b>John</b>',
        email: 'test@example.com'
      }
    }
    const clean = sanitizeObject(dirty)
    expect(clean.user.name).toBe('John')
    expect(clean.user.email).toBe('test@example.com')
  })

  it('debe respetar excludeKeys', () => {
    const dirty = {
      password: '<script>secret</script>',
      name: '<b>John</b>'
    }
    const clean = sanitizeObject(dirty, ['password'])
    expect(clean.password).toBe('<script>secret</script>')
    expect(clean.name).toBe('John')
  })

  it('debe manejar arrays', () => {
    const dirty = ['<b>Item1</b>', '<script>hack</script>Item2']
    const clean = sanitizeObject(dirty)
    expect(clean[0]).toBe('Item1')
    expect(clean[1]).toBe('Item2')
  })
})

describe('sanitizeFormData', () => {
  it('debe sanitizar campos de texto por defecto', () => {
    const formData = {
      nombre: '<script>hack()</script>Juan',
      email: 'test@example.com',
      cantidad: 10
    }
    const clean = sanitizeFormData(formData)
    expect(clean.nombre).toBe('Juan')
    expect(clean.email).toBe('test@example.com')
    expect(clean.cantidad).toBe(10)
  })

  it('debe permitir HTML en campos especificados', () => {
    const formData = {
      nombre: '<b>Juan</b>',
      descripcion: '<b>Bold</b> text'
    }
    const clean = sanitizeFormData(formData, { htmlFields: ['descripcion'] })
    expect(clean.nombre).toBe('Juan')
    expect(clean.descripcion).toBe('<b>Bold</b> text')
  })

  it('debe skip campos especificados', () => {
    const formData = {
      password: '<secret>123',
      nombre: '<b>Juan</b>'
    }
    const clean = sanitizeFormData(formData, { skipFields: ['password'] })
    expect(clean.password).toBe('<secret>123')
    expect(clean.nombre).toBe('Juan')
  })
})

describe('escapeRegex', () => {
  it('debe escapar caracteres especiales de regex', () => {
    expect(escapeRegex('hello.world')).toBe('hello\\.world')
    expect(escapeRegex('test*')).toBe('test\\*')
    expect(escapeRegex('(test)')).toBe('\\(test\\)')
    expect(escapeRegex('[a-z]')).toBe('\\[a-z\\]')
  })

  it('debe manejar null y undefined', () => {
    expect(escapeRegex(null)).toBe('')
    expect(escapeRegex(undefined)).toBe('')
  })
})

describe('truncateText', () => {
  it('debe truncar texto largo', () => {
    expect(truncateText('Hello World', 8)).toBe('Hello...')
    expect(truncateText('Short', 10)).toBe('Short')
  })

  it('debe usar sufijo personalizado', () => {
    expect(truncateText('Hello World', 8, '…')).toBe('Hello W…')
  })

  it('debe sanitizar antes de truncar', () => {
    expect(truncateText('<b>Hello</b> World', 8)).toBe('Hello...')
  })

  it('debe manejar null y undefined', () => {
    expect(truncateText(null, 10)).toBe('')
    expect(truncateText(undefined, 10)).toBe('')
  })
})
