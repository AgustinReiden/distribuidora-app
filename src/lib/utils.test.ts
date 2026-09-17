import { describe, it, expect } from 'vitest'
import { cn } from './utils'

// `cn()` es la base de todos los primitivos de UI. Estos casos fijan lo que un
// cambio de version de tailwind-merge puede romper SIN que falle nada mas: el
// resultado es un string de clases y el unico sintoma es visual.

describe('cn — conflictos basicos', () => {
  it('la ultima clase del mismo grupo gana', () => {
    expect(cn('p-2', 'p-4')).toBe('p-4')
    expect(cn('px-4', 'px-6')).toBe('px-6')
    expect(cn('rounded-lg', 'rounded-xl')).toBe('rounded-xl')
    expect(cn('text-sm', 'text-[14px]')).toBe('text-[14px]')
    expect(cn('bg-blue-600', 'bg-red-600')).toBe('bg-red-600')
  })

  it('clases de grupos distintos conviven', () => {
    expect(cn('text-white', 'text-sm')).toBe('text-white text-sm')
    expect(cn('bg-white', 'dark:bg-gray-800')).toBe('bg-white dark:bg-gray-800')
  })

  it('descarta falsy y acepta condicionales, como clsx', () => {
    const fullWidth = false
    expect(cn('relative', fullWidth && 'w-full', null, undefined, '')).toBe('relative')
    expect(cn('relative', { 'w-full': true, hidden: false })).toBe('relative w-full')
  })

  it('un color custom del tema se trata como color y no como otra cosa', () => {
    expect(cn('bg-brand-600', 'bg-red-600')).toBe('bg-red-600')
    expect(cn('text-brand-600', 'text-white')).toBe('text-white')
    expect(cn('text-brand-600', 'text-sm')).toBe('text-brand-600 text-sm')
  })
})

describe('cn — degrade de Tailwind 3 (el bug de tailwind-merge 3.x)', () => {
  // Con tailwind-merge 3.x (hecho para Tailwind 4, donde el degrade se llama
  // `bg-linear-to-*`) `bg-gradient-to-br` caia en el grupo de COLOR de fondo y
  // cualquier `bg-*` posterior lo borraba. En CSS no chocan: uno es
  // background-image y el otro background-color.
  it('un color de fondo posterior NO apaga el degrade', () => {
    expect(cn('bg-gradient-to-br from-green-500 to-green-600', 'bg-emerald-600')).toBe(
      'bg-gradient-to-br from-green-500 to-green-600 bg-emerald-600',
    )
    expect(cn('bg-gradient-to-br from-brand-500 to-brand-700', 'bg-white')).toBe(
      'bg-gradient-to-br from-brand-500 to-brand-700 bg-white',
    )
  })

  it('dos direcciones de degrade si chocan, y `bg-none` lo apaga', () => {
    expect(cn('bg-gradient-to-br', 'bg-gradient-to-r')).toBe('bg-gradient-to-r')
    expect(cn('bg-gradient-to-br', 'bg-none')).toBe('bg-none')
  })

  it('las paradas del degrade se pisan entre si', () => {
    expect(cn('from-green-500 to-green-600', 'from-brand-500')).toBe('to-green-600 from-brand-500')
  })
})

describe('cn — sombras propias del tema (shadow-warm*)', () => {
  // Sin declararlas, `shadow-warm` cae en el grupo de COLOR de sombra y convive
  // con `shadow-md`: quedan las dos y gana la que este mas abajo en el CSS.
  it('una sombra warm y una de Tailwind se pisan', () => {
    expect(cn('shadow-warm', 'shadow-md')).toBe('shadow-md')
    expect(cn('shadow-md', 'shadow-warm-lg')).toBe('shadow-warm-lg')
    expect(cn('shadow-warm', 'shadow-warm-md')).toBe('shadow-warm-md')
  })

  it('respeta variantes', () => {
    expect(cn('hover:shadow-warm-md', 'hover:shadow-lg')).toBe('hover:shadow-lg')
    expect(cn('shadow-warm', 'hover:shadow-warm-md')).toBe('shadow-warm hover:shadow-warm-md')
    expect(cn('dark:shadow-warm', 'dark:shadow-none')).toBe('dark:shadow-none')
  })

  it('el COLOR de sombra sigue siendo otro grupo', () => {
    expect(cn('shadow-warm', 'shadow-stone-200')).toBe('shadow-warm shadow-stone-200')
    expect(cn('shadow-lg', 'shadow-black/10')).toBe('shadow-lg shadow-black/10')
  })
})

describe('cn — alias viejos de flex (validos en Tailwind 3)', () => {
  it('flex-shrink-* y shrink-* son el mismo grupo', () => {
    expect(cn('flex-shrink-0', 'shrink-0')).toBe('shrink-0')
    expect(cn('shrink-0', 'flex-shrink')).toBe('flex-shrink')
  })

  it('flex-grow-* y grow-* son el mismo grupo', () => {
    expect(cn('flex-grow', 'grow-0')).toBe('grow-0')
  })
})

describe('cn — call sites reales que no pueden cambiar', () => {
  it('Dialog: el contenido acepta un ancho del consumidor', () => {
    const base =
      'fixed left-[50%] top-[50%] z-50 flex flex-col w-full max-w-md translate-x-[-50%] translate-y-[-50%] bg-white dark:bg-gray-800 shadow-xl rounded-xl max-h-[90vh] overflow-hidden'
    const out = cn(base, 'focus:outline-none', 'max-w-4xl')
    expect(out).toContain('max-w-4xl')
    expect(out).not.toContain('max-w-md')
    expect(out).toContain('bg-white')
    expect(out).toContain('dark:bg-gray-800')
    expect(out).toContain('shadow-xl')
  })

  it('Dialog: header y footer conservan flex-shrink-0 junto a lo que llegue', () => {
    expect(cn('flex justify-between items-center p-4 border-b dark:border-gray-700 flex-shrink-0', 'p-6')).toBe(
      'flex justify-between items-center border-b dark:border-gray-700 flex-shrink-0 p-6',
    )
  })

  it('PedidoToolbar: el CTA con degrade llega entero', () => {
    const fullWidth = [true].includes(true)
    const out = cn(
      'group relative inline-flex items-center gap-2.5 h-11 px-6 rounded-lg text-[14px] font-semibold',
      'text-white',
      'bg-gradient-to-br from-green-500 to-green-600',
      'hover:from-green-500 hover:to-green-700 hover:-translate-y-px',
      'transition-[transform,box-shadow,background] duration-200',
      fullWidth && 'w-full justify-center',
    )
    for (const clase of [
      'bg-gradient-to-br',
      'from-green-500',
      'to-green-600',
      'hover:from-green-500',
      'hover:to-green-700',
      'text-white',
      'text-[14px]',
      'h-11',
      'w-full',
      'justify-center',
    ]) {
      expect(out.split(' ')).toContain(clase)
    }
  })
})
