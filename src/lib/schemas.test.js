import { describe, it, expect } from 'vitest'
import { z } from 'zod'
import { validateForm, getFirstError } from './schemas'

const testSchema = z.object({
  nombre: z
    .string()
    .min(1, { message: 'El nombre es obligatorio' })
    .transform(val => val.trim())
    .refine(val => val.length >= 2, { message: 'El nombre debe tener al menos 2 caracteres' }),

  tipo: z.enum(['minorista', 'mayorista'], { error: 'Tipo inválido' })
})

describe('Helpers de validación', () => {
  describe('validateForm', () => {
    it('retorna success con los datos parseados', () => {
      const result = validateForm(testSchema, { nombre: 'Test', tipo: 'minorista' })
      expect(result.success).toBe(true)
      expect(result.data).toEqual({ nombre: 'Test', tipo: 'minorista' })
    })

    it('retorna errores por campo cuando falla la validación', () => {
      const result = validateForm(testSchema, { nombre: '', tipo: 'invalido' })
      expect(result.success).toBe(false)
      expect(result.errors.nombre).toBeDefined()
      expect(result.errors.tipo).toBeDefined()
    })
  })

  describe('getFirstError', () => {
    it('retorna null para datos válidos', () => {
      const error = getFirstError(testSchema, { nombre: 'Test', tipo: 'minorista' })
      expect(error).toBeNull()
    })

    it('retorna primer error para datos inválidos', () => {
      const error = getFirstError(testSchema, { nombre: '', tipo: 'invalido' })
      expect(error).toBeDefined()
      expect(typeof error).toBe('string')
    })
  })
})
