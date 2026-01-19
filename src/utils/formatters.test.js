import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  formatPrecio,
  formatCurrency,
  formatCurrencyCompact,
  formatDate,
  formatDateTime,
  formatTimeAgo,
  formatCuit,
  unformatCuit,
  isValidCuit,
  formatDni,
  formatTelefono,
  getEstadoColor,
  getEstadoLabel,
  getEstadoPagoColor,
  getEstadoPagoLabel,
  truncate,
  capitalize,
  formatPercent,
  formatNumber,
  isValidEmail
} from './formatters'

describe('Formatters de Moneda', () => {
  describe('formatPrecio', () => {
    it('formatea precio correctamente', () => {
      const result = formatPrecio(1234.56)
      expect(result).toContain('1.234')
    })

    it('maneja null/undefined como 0', () => {
      expect(formatPrecio(null)).toContain('0')
      expect(formatPrecio(undefined)).toContain('0')
    })

    it('maneja números negativos', () => {
      const result = formatPrecio(-500)
      expect(result).toContain('500')
    })
  })

  describe('formatCurrency', () => {
    it('formatea moneda con símbolo por defecto', () => {
      expect(formatCurrency(1000)).toBe('$1.000,00')
    })

    it('formatea moneda sin símbolo', () => {
      expect(formatCurrency(1000, false)).toBe('1.000,00')
    })

    it('maneja valores inválidos', () => {
      expect(formatCurrency(null)).toBe('$0,00')
      expect(formatCurrency(undefined)).toBe('$0,00')
      expect(formatCurrency(NaN)).toBe('$0,00')
    })

    it('formatea decimales correctamente', () => {
      expect(formatCurrency(99.99)).toBe('$99,99')
    })
  })

  describe('formatCurrencyCompact', () => {
    it('formatea millones como M', () => {
      expect(formatCurrencyCompact(1500000)).toBe('$1.5M')
    })

    it('formatea miles como K', () => {
      expect(formatCurrencyCompact(2500)).toBe('$2.5K')
    })

    it('montos pequeños usan formato normal', () => {
      expect(formatCurrencyCompact(500)).toBe('$500,00')
    })

    it('maneja valores inválidos', () => {
      expect(formatCurrencyCompact(null)).toBe('$0')
      expect(formatCurrencyCompact(NaN)).toBe('$0')
    })
  })
})

describe('Formatters de Fecha', () => {
  describe('formatDate', () => {
    it('formatea fecha correctamente', () => {
      const result = formatDate('2024-06-15')
      expect(result).toMatch(/15\/06\/2024/)
    })

    it('maneja fechas vacías', () => {
      expect(formatDate(null)).toBe('')
      expect(formatDate('')).toBe('')
    })

    it('maneja Date objects', () => {
      const date = new Date(2024, 5, 15)
      const result = formatDate(date)
      expect(result).toMatch(/15\/06\/2024/)
    })

    it('maneja fechas inválidas', () => {
      expect(formatDate('invalid')).toBe('')
    })
  })

  describe('formatDateTime', () => {
    it('formatea fecha y hora', () => {
      const result = formatDateTime('2024-06-15T14:30:00')
      // Verificar que contiene la fecha (formato puede variar)
      expect(result).toMatch(/15/)
      expect(result).toMatch(/06/)
      expect(result).toMatch(/2024/)
    })

    it('maneja valores vacíos', () => {
      expect(formatDateTime(null)).toBe('')
    })
  })

  describe('formatTimeAgo', () => {
    beforeEach(() => {
      vi.useFakeTimers()
      vi.setSystemTime(new Date('2024-06-15T12:00:00'))
    })

    afterEach(() => {
      vi.useRealTimers()
    })

    it('muestra "hace un momento" para segundos', () => {
      const date = new Date('2024-06-15T11:59:30')
      expect(formatTimeAgo(date)).toBe('hace un momento')
    })

    it('muestra minutos correctamente', () => {
      const date = new Date('2024-06-15T11:55:00')
      expect(formatTimeAgo(date)).toBe('hace 5 minutos')
    })

    it('muestra "1 minuto" en singular', () => {
      const date = new Date('2024-06-15T11:59:00')
      expect(formatTimeAgo(date)).toBe('hace 1 minuto')
    })

    it('muestra horas correctamente', () => {
      const date = new Date('2024-06-15T09:00:00')
      expect(formatTimeAgo(date)).toBe('hace 3 horas')
    })

    it('muestra días correctamente', () => {
      const date = new Date('2024-06-13T12:00:00')
      expect(formatTimeAgo(date)).toBe('hace 2 dias')
    })

    it('muestra fecha para más de 7 días', () => {
      const date = new Date('2024-06-01T12:00:00')
      expect(formatTimeAgo(date)).toMatch(/01\/06\/2024/)
    })

    it('maneja valores vacíos', () => {
      expect(formatTimeAgo(null)).toBe('')
      expect(formatTimeAgo('')).toBe('')
    })
  })
})

describe('Formatters de Documentos', () => {
  describe('formatCuit', () => {
    it('formatea CUIT completo correctamente', () => {
      expect(formatCuit('20123456789')).toBe('20-12345678-9')
    })

    it('formatea CUIT parcial', () => {
      expect(formatCuit('20')).toBe('20')
      expect(formatCuit('20123')).toBe('20-123')
    })

    it('maneja valores vacíos', () => {
      expect(formatCuit('')).toBe('')
      expect(formatCuit(null)).toBe('')
    })

    it('remueve caracteres no numéricos', () => {
      expect(formatCuit('20-12345678-9')).toBe('20-12345678-9')
    })
  })

  describe('unformatCuit', () => {
    it('remueve formato de CUIT', () => {
      expect(unformatCuit('20-12345678-9')).toBe('20123456789')
    })

    it('maneja CUIT sin formato', () => {
      expect(unformatCuit('20123456789')).toBe('20123456789')
    })

    it('maneja valores vacíos', () => {
      expect(unformatCuit('')).toBe('')
      expect(unformatCuit(null)).toBe('')
    })
  })

  describe('isValidCuit', () => {
    it('valida CUIT de 11 dígitos', () => {
      expect(isValidCuit('20123456789')).toBe(true)
      expect(isValidCuit('20-12345678-9')).toBe(true)
    })

    it('rechaza CUIT con menos dígitos', () => {
      expect(isValidCuit('2012345678')).toBe(false)
    })

    it('rechaza CUIT con más dígitos', () => {
      expect(isValidCuit('201234567890')).toBe(false)
    })
  })

  describe('formatDni', () => {
    it('formatea DNI correctamente', () => {
      expect(formatDni('12345678')).toBe('12.345.678')
    })

    it('formatea DNI parcial', () => {
      expect(formatDni('12')).toBe('12')
      expect(formatDni('12345')).toBe('12.345')
    })

    it('maneja valores vacíos', () => {
      expect(formatDni('')).toBe('')
    })
  })

  describe('formatTelefono', () => {
    it('formatea teléfono correctamente', () => {
      expect(formatTelefono('1122334455')).toBe('(112) 2334-455')
    })

    it('formatea teléfono parcial', () => {
      expect(formatTelefono('112')).toBe('112')
      expect(formatTelefono('1122334')).toBe('(112) 2334')
    })

    it('maneja valores vacíos', () => {
      expect(formatTelefono('')).toBe('')
    })
  })
})

describe('Estados y Labels', () => {
  describe('getEstadoColor', () => {
    it('retorna color correcto para cada estado', () => {
      expect(getEstadoColor('pendiente')).toContain('yellow')
      expect(getEstadoColor('en_preparacion')).toContain('orange')
      expect(getEstadoColor('asignado')).toContain('blue')
      expect(getEstadoColor('en_camino')).toContain('blue')
      expect(getEstadoColor('entregado')).toContain('green')
      expect(getEstadoColor('cancelado')).toContain('red')
    })

    it('retorna gris para estado desconocido', () => {
      expect(getEstadoColor('unknown')).toContain('gray')
    })
  })

  describe('getEstadoLabel', () => {
    it('retorna label correcto para cada estado', () => {
      expect(getEstadoLabel('pendiente')).toBe('Pendiente')
      expect(getEstadoLabel('en_preparacion')).toBe('En preparación')
      expect(getEstadoLabel('asignado')).toBe('Asignado')
      expect(getEstadoLabel('en_camino')).toBe('En camino')
      expect(getEstadoLabel('entregado')).toBe('Entregado')
      expect(getEstadoLabel('cancelado')).toBe('Cancelado')
    })

    it('retorna el mismo valor para estado desconocido', () => {
      expect(getEstadoLabel('otro')).toBe('otro')
    })
  })

  describe('getEstadoPagoColor', () => {
    it('retorna colores correctos', () => {
      expect(getEstadoPagoColor('pagado')).toContain('green')
      expect(getEstadoPagoColor('parcial')).toContain('yellow')
      expect(getEstadoPagoColor('pendiente')).toContain('red')
    })
  })

  describe('getEstadoPagoLabel', () => {
    it('retorna labels correctos', () => {
      expect(getEstadoPagoLabel('pagado')).toBe('Pagado')
      expect(getEstadoPagoLabel('parcial')).toBe('Pago Parcial')
      expect(getEstadoPagoLabel('pendiente')).toBe('Pago Pendiente')
    })
  })
})

describe('Utilidades Generales', () => {
  describe('truncate', () => {
    it('trunca strings largos', () => {
      expect(truncate('Este es un texto muy largo', 10)).toBe('Este es...')
    })

    it('no modifica strings cortos', () => {
      expect(truncate('Corto', 10)).toBe('Corto')
    })

    it('usa sufijo personalizado', () => {
      expect(truncate('Texto largo aqui', 10, '…')).toBe('Texto lar…')
    })

    it('maneja valores vacíos', () => {
      expect(truncate('', 10)).toBe('')
      expect(truncate(null, 10)).toBe('')
    })
  })

  describe('capitalize', () => {
    it('capitaliza primera letra', () => {
      expect(capitalize('hello')).toBe('Hello')
      expect(capitalize('HELLO')).toBe('Hello')
    })

    it('maneja valores vacíos', () => {
      expect(capitalize('')).toBe('')
      expect(capitalize(null)).toBe('')
    })
  })

  describe('formatPercent', () => {
    it('formatea porcentaje correctamente', () => {
      expect(formatPercent(0.15)).toBe('15.0%')
      expect(formatPercent(0.5)).toBe('50.0%')
      expect(formatPercent(1)).toBe('100.0%')
    })

    it('respeta decimales', () => {
      expect(formatPercent(0.1555, 2)).toBe('15.55%')
    })

    it('maneja valores inválidos', () => {
      expect(formatPercent(null)).toBe('0%')
      expect(formatPercent(NaN)).toBe('0%')
    })
  })

  describe('formatNumber', () => {
    it('formatea números con separador de miles', () => {
      expect(formatNumber(1234567)).toBe('1.234.567')
    })

    it('maneja valores inválidos', () => {
      expect(formatNumber(null)).toBe('0')
      expect(formatNumber(NaN)).toBe('0')
    })
  })

  describe('isValidEmail', () => {
    it('valida emails correctos', () => {
      expect(isValidEmail('test@example.com')).toBe(true)
      expect(isValidEmail('user.name@domain.co')).toBe(true)
    })

    it('rechaza emails inválidos', () => {
      expect(isValidEmail('invalid')).toBe(false)
      expect(isValidEmail('no@domain')).toBe(false)
      expect(isValidEmail('@domain.com')).toBe(false)
      expect(isValidEmail('')).toBe(false)
      expect(isValidEmail(null)).toBe(false)
    })
  })
})
