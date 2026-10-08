/* eslint-disable no-undef */
import '@testing-library/jest-dom'
import { cleanup, configure } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { afterEach, vi } from 'vitest'
import 'fake-indexeddb/auto'

// Esperas de findBy/waitFor: el default de RTL es 1 s. Es una cota para el caso
// en que el elemento NO aparece: cuando aparece, findBy vuelve en el acto y no
// cuesta nada. Con la suite completa y la máquina cargada, un render pesado
// (modales de pedido y compra) pasaba el segundo y el test fallaba con "no
// encuentra la option/el botón" aunque el elemento estaba por llegar (#951, #960).
configure({ asyncUtilTimeout: 5000 })

// Lo que un handler hace DESPUÉS de un await (cerrar un form, mostrar un error,
// elegir el cliente recién creado) queda fuera del act() del clic y React lo
// pinta en otra vuelta del event loop. Testing Library cierra cada acción con un
// único setTimeout(0), y que ese render llegue antes es una carrera: en CI
// (Linux, Node 20, coverage) se pierde ~1 de cada 20 veces (#1006). Un test que
// mira ese estado lo espera con findBy/waitFor, nunca con getBy/queryBy en el acto.
//
// TEST_SIN_DRENAJE=1 saca ese setTimeout(0) y hace perder la carrera SIEMPRE: un
// test que dependa de ella falla en cada corrida en vez de una de cada veinte.
// Sirve para barrer la suite (`TEST_SIN_DRENAJE=1 npm run test:run`); no es el
// modo normal. Falso positivo conocido: VistaMisEntregas, que depende del GC de
// TanStack (`gcTime: 0`, un setTimeout), no de un render.
if (process.env.TEST_SIN_DRENAJE) {
  configure({
    asyncWrapper: async cb => {
      const previo = globalThis.IS_REACT_ACT_ENVIRONMENT
      globalThis.IS_REACT_ACT_ENVIRONMENT = false
      try { return await cb() } finally { globalThis.IS_REACT_ACT_ENVIRONMENT = previo }
    },
  })
}

// userEvent.setup() espera un setTimeout(0) entre cada acción (delay: 0). En un
// flujo de 60 teclas sobre un modal pesado son 60 vueltas de event loop que, con
// la máquina cargada, se pagan caro (~20 % del test del sheet de pedido). Con
// delay: null las acciones siguen siendo secuenciales y sin timers, y los tests
// que pasan su propio `advanceTimers` o `delay` lo conservan (va después).
// Ese setTimeout(0) va ANTES de cada acción, no después: no protege la carrera
// de arriba, sólo la hacía más rara (0 en 90 contra 6 en 120 en el peor test).
// Arreglados los tests que dependían de ella, se queda en null (#1006).
const setupOriginal = userEvent.setup.bind(userEvent)
userEvent.setup = (options) => setupOriginal({ delay: null, ...options })

// Cleanup after each test
afterEach(() => {
  cleanup()
  // Sin esto, lo que escribe un test se filtra al siguiente.
  localStorageStore.clear()
})

// localStorage: almacenamiento REAL en memoria, pero espiable.
//
// Antes eran cuatro vi.fn() pelados: getItem devolvia undefined incluso despues
// de un setItem, asi que nada que dependiera de storage se podia testear. Dos
// suites terminaron construyendose su propio localStorage en memoria para
// esquivarlo (useAsync.test.js y rutaOfflineCache.test.ts).
//
// No alcanza con poner un storage funcional a secas: ErrorBoundary.test.jsx
// hace expect(localStorage.removeItem).toHaveBeenCalledWith(...). Por eso cada
// metodo guarda de verdad Y es un vi.fn(): sirve para las dos cosas.
const localStorageStore = new Map()
const localStorageMock = {
  getItem: vi.fn(k => (localStorageStore.has(String(k)) ? localStorageStore.get(String(k)) : null)),
  setItem: vi.fn((k, v) => { localStorageStore.set(String(k), String(v)) }),
  removeItem: vi.fn(k => { localStorageStore.delete(String(k)) }),
  clear: vi.fn(() => { localStorageStore.clear() }),
  key: vi.fn(i => Array.from(localStorageStore.keys())[i] ?? null),
  get length() { return localStorageStore.size },
}
global.localStorage = localStorageMock
globalThis.localStorage = localStorageMock

// Mock matchMedia
Object.defineProperty(window, 'matchMedia', {
  writable: true,
  value: vi.fn().mockImplementation(query => ({
    matches: false,
    media: query,
    onchange: null,
    addListener: vi.fn(),
    removeListener: vi.fn(),
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
    dispatchEvent: vi.fn(),
  })),
})

// ResizeObserver: tiene que ser una CLASE, no un vi.fn() con implementacion
// flecha. @floating-ui (el posicionador de Radix: DropdownMenu, Select, Popover)
// hace `new ResizeObserver(...)`, y una flecha se puede llamar pero no
// construir: "is not a constructor" al abrir cualquier menu en jsdom (#735).
global.ResizeObserver = class ResizeObserver {
  observe() {}
  unobserve() {}
  disconnect() {}
}

// Mock crypto for AES-GCM tests and Dexie.js
Object.defineProperty(global, 'crypto', {
  value: {
    subtle: {
      generateKey: vi.fn(),
      encrypt: vi.fn(),
      decrypt: vi.fn(),
      exportKey: vi.fn(),
      importKey: vi.fn(),
      // Required by Dexie.js for content hashing
      digest: vi.fn().mockImplementation(async (algorithm, data) => {
        // Simple mock that returns a fake hash based on data length
        const hashLength = algorithm === 'SHA-256' ? 32 : 20
        const result = new Uint8Array(hashLength)
        for (let i = 0; i < hashLength; i++) {
          result[i] = (data.length + i) % 256
        }
        return result.buffer
      }),
    },
    getRandomValues: (arr) => {
      for (let i = 0; i < arr.length; i++) {
        arr[i] = Math.floor(Math.random() * 256)
      }
      return arr
    },
  },
})
