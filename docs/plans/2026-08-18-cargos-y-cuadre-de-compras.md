# Cargos prorrateados y cuadre fiscal de compras — Plan de implementación

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Que una factura de compra con flete, pallets, separadores y bonificaciones promocionales cargue el costo real correcto en cada producto, y que el impuesto interno cuadre contra el papel sin ajuste manual.

**Architecture:** Una tabla `compra_cargos` con su vector de pesos (`compra_cargo_repartos`) modela todo concepto que no es un renglón de producto. El prorrateo es canónico en la RPC; TypeScript replica el mismo motor sólo para la vista previa del modal, con un test de espejo que ata ambas implementaciones a la factura real `A0005-00461415`.

**Tech Stack:** PostgreSQL/Supabase (RPC plpgsql, RLS), React + TypeScript, Vitest, TanStack Query.

**Diseño de referencia:** `docs/plans/2026-08-18-cargos-y-cuadre-de-compras-design.md` (commit `54dbd94`). Leerlo antes de empezar — explica el *por qué* de cada decisión.

---

## Antes de empezar: cosas que te van a morder

Leé esto entero. Cada punto costó una investigación.

1. **Corré vitest SIEMPRE con `VITEST_MAX_WORKERS=2`, incluido el `git commit`.** Sin eso vitest se autosatura en esta máquina y se cuelga indefinidamente: ya mató a un subagente por watchdog a los 600s y colgó dos commits durante 10 minutos, dejando 26 procesos node huérfanos. Con 2 workers la suite entera corre en **91 segundos**; sin el tope, o tarda 220s o no termina nunca.

   ```bash
   VITEST_MAX_WORKERS=2 npx vitest run src/utils/prorrateoCompra.test.ts
   VITEST_MAX_WORKERS=2 git commit -m "..."
   ```

   El hook de pre-commit corre la suite completa, por eso el commit también necesita la variable. `vite.config.js:374` ya la respeta. Si usás la herramienta Bash, pasale `timeout` de 600000 igual.

2. **`redondear()` de `src/utils/calculations.ts` NO es equivalente a `round(numeric,2)` de Postgres, y arreglar el signo no alcanza.** Hay dos divergencias distintas y es fácil ver sólo la primera:
   - **Signo:** `redondear` usa `Math.round`, que redondea medio hacia +∞ (`Math.round(-0.5) === -0`); Postgres redondea medio alejándose del cero (`round(-0.5) = -1`). Las bonificaciones son cargos negativos, así que esto pega.
   - **Representación (la grave):** `Math.abs(1.005) * 100` da `100.49999999999998`, no `100.5`, así que `Math.round` baja y Postgres sube. Verificado contra prod: `1.005 → 1.01` en PG contra `1.00` en JS; igual con `0.145`, `0.565`, `1.025`. En montos de centavo impar repartidos entre 2 líneas, en el rango $1.000–1.400, **divergen el 11,5%**.

   Lo traicionero es que depende de la magnitud de forma impredecible: con los números del flete (73.076,92) no diverge nunca. **Un test de espejo escrito sobre los datos del flete da verde y consagra el bug.** Por eso el test de Task 1 compara contra una tabla calculada en Postgres, no contra valores elegidos en JS.

   Y el fondo: ninguna función sobre `double` puede ser espejo universal de `numeric`, porque `1.005` como double *no es* 1.005. El fix por desplazamiento de exponente cubre el rango del dinero, que es lo que importa acá.

3. **JavaScript acumula error al sumar muchos floats; Postgres `numeric` no.** Sumar los 21 repartos del flete en JS da `1899999.9999999995`, no `1900000`. Cada parte es exacta al centavo, el total no. En los tests de TS, releé el total con `redondearSQL(total, 2)` antes de comparar. En SQL no hace falta: `numeric` es decimal exacto. Esta asimetría es esperada y no significa que el espejo esté roto.

4. **`actualizar_compra_items` hace `DELETE FROM compra_items`.** Una FK de `compra_cargo_repartos` con `ON DELETE CASCADE` vaciaría los repartos en silencio al editar una compra. Por eso la RPC de edición recibe cargos y los reescribe (Task 10).

5. **Nunca dejes dos sobrecargas de una función con rangos de aridad superpuestos.** Una de 3 argumentos y otra de 4 con `DEFAULT` producen `PGRST203` en runtime, invisible para tsc y para los tests. Es la trampa de la mig 176. Se dropea la vieja, no se deja wrapper.

6. **`migrations/` es una vista curada, no es 1:1 con producción.** Verificá siempre contra el catálogo vivo (`pg_get_functiondef`), nunca asumas que el archivo del repo es lo que corre. Ver `migrations/MANIFEST.md` y `npm run check:migrations`.

7. **Los worktrees no tienen `.env`.** Si ves pantalla en blanco o ~22 errores de typecheck, es ambiental. Verificá con `npm run build`.

8. **Nuestras migraciones son la `192`, `193` y `194`.** Y el número hay que reconfirmarlo antes de aplicar, porque **este plan ya perdió el número dos veces**.

   - Primero reservó la `182`, y mientras trabajábamos se mergeó `182_pagos_fecha_en_hora_argentina`. Renumeramos a 183-185.
   - Después perdió la `183`, cuando otra rama aplicó `183_cerrar_recorridos_terminados`. Y en el mismo rato aparecieron la `186`, `187`, `188` y `189` de otras dos ramas. Renumeramos a 190-192.

   **Mirar tres fuentes, no una.** El repo local es la que menos sirve: desde adentro de un worktree la colisión es **invisible**, porque conserva el estado de su punto de partida y muestra como "última" una migración que dejó de serlo hace rato.

   ```bash
   git fetch origin                                    # 1. origin/main
   # 2. el ledger: select max(...) from supabase_migrations.schema_migrations
   # 3. TODAS las ramas abiertas — es donde la colisión ocurre de verdad:
   for b in $(git branch -a --format='%(refname:short)' | grep -v HEAD); do
     git ls-tree --name-only "$b" migrations/ 2>/dev/null | grep -oE '1[0-9]{2}_[a-z_]+' | sort -u | tail -2
   done | sort -u
   ```

   El costo no es renombrar el `.sql`: son las referencias cruzadas ya commiteadas —docstrings, `COMMENT ON`, nombres de helpers como `_mig193_reemplazo_unico`, el plan entero— más el rebase. Por eso conviene **reservar tarde**: escribir el contenido primero y numerar al final.

9. **Hay dos implementaciones del hook de compras.** `src/hooks/queries/useComprasQuery.ts` es la viva (la usa `ComprasContainer`). `src/hooks/supabase/useCompras.ts` sólo se exporta desde un barrel y su `registrarCompra` ni siquiera manda `p_tipo_factura` — está muerta. **No la toques**; si algo la usara, se rompería igual hoy.

---

## Fase 1 — Motor de prorrateo en TypeScript

Se hace primero porque es puro, testeable sin base de datos, y fija la semántica que después el SQL tiene que replicar.

### Task 1: Helper de redondeo compatible con Postgres

**Files:**
- Modify: `src/utils/calculations.ts`
- Test: `src/utils/calculations.prorrateo.test.ts` (crear)

**Step 1: Escribir el test que falla**

```ts
import { describe, it, expect } from 'vitest'
import { redondearSQL } from './calculations'

describe('redondearSQL (espejo de round(numeric, n) de Postgres)', () => {
  it('redondea medio ALEJANDOSE del cero, no hacia +infinito', () => {
    // Math.round(-0.5) === -0 → esto es lo que NO queremos
    expect(redondearSQL(-0.005, 2)).toBe(-0.01)
    expect(redondearSQL(0.005, 2)).toBe(0.01)
    expect(redondearSQL(-1.235, 2)).toBe(-1.24)
    expect(redondearSQL(1.235, 2)).toBe(1.24)
  })

  it('no devuelve -0 (rompe toBe con Object.is)', () => {
    expect(Object.is(redondearSQL(-0.001, 2), 0)).toBe(true)
  })

  it('casos triviales', () => {
    expect(redondearSQL(1900000 / 26, 2)).toBe(73076.92)
    expect(redondearSQL(0, 2)).toBe(0)
  })
})
```

**Step 2: Correr y verificar que falla**

Run: `npx vitest run src/utils/calculations.prorrateo.test.ts`
Expected: FAIL — `redondearSQL is not exported`

**Step 3: Implementar**

En `src/utils/calculations.ts`, junto a `redondear` (~línea 465):

```ts
export function redondearSQL(valor: number, decimales: number = 2): number {
  if (!Number.isFinite(valor)) return NaN;
  const signo = valor < 0 ? -1 : 1;
  const abs = Math.abs(valor);
  // Fuera de [1e-6, 1e21) String() usa notacion exponencial y el desplazamiento
  // por string produciria "1e-7e2". Debajo de 1e-6 el resultado a 2 decimales es
  // 0 igual; arriba de 1e21 no hay montos de dinero.
  if (abs !== 0 && (abs < 1e-6 || abs >= 1e21)) {
    const factor = Math.pow(10, decimales);
    return (signo * Math.round(abs * factor) / factor) + 0;
  }
  const desplazado = Math.round(Number(`${abs}e${decimales}`));
  return signo * Number(`${desplazado}e-${decimales}`) + 0;  // el + 0 normaliza -0
}
```

El desplazamiento por string recupera la intención decimal del double vía su representación round-trip más corta: `String(1.005)` es `"1.005"`, así que `"1.005e2"` da `100.5` limpio y redondea a `1.01` como Postgres. Multiplicar por 100 no lo logra.

Agregarla al `export default` del final del archivo.

**El test tiene que comparar contra una tabla calculada en Postgres**, no contra valores elegidos a mano en JS — si no, es una tautología. Los valores de referencia salen de correr `round(v,2)` en la base sobre valores que caen en el medio centavo:

```ts
const REFERENCIA_POSTGRES: Array<[number, number]> = [
  [1.005, 1.01], [1.015, 1.02], [1.025, 1.03], [1.035, 1.04], [1.045, 1.05],
  [0.145, 0.15], [0.565, 0.57], [0.005, 0.01], [2.675, 2.68], [8.045, 8.05],
  [-1.005, -1.01], [-1.025, -1.03], [-0.145, -0.15], [-0.565, -0.57],
  [-0.005, -0.01], [-2.675, -2.68], [1234.565, 1234.57], [73076.925, 73076.93],
  [36538.455, 36538.46], [292307.685, 292307.69], [1900000.005, 1900000.01],
  [1.115, 1.12], [1.215, 1.22], [4.985, 4.99],
]

it.each(REFERENCIA_POSTGRES)('coincide con round(%s, 2) de Postgres', (valor, esperado) => {
  expect(redondearSQL(valor)).toBe(esperado)
})
```

**Step 4: Correr y verificar que pasa**

Run: `npx vitest run src/utils/calculations.prorrateo.test.ts`
Expected: PASS (3 tests)

**Step 5: Commit**

```bash
git add src/utils/calculations.ts src/utils/calculations.prorrateo.test.ts && git commit -m "Agregar redondeo compatible con Postgres para el prorrateo"
```

---

### Task 2: Reparto de un cargo sobre un vector de pesos

**Files:**
- Create: `src/utils/prorrateoCompra.ts`
- Test: `src/utils/prorrateoCompra.test.ts`

**Step 1: Escribir el test que falla**

```ts
import { describe, it, expect } from 'vitest'
import { prorratearCargo } from './prorrateoCompra'
import { redondearSQL } from './calculations'

describe('prorratearCargo', () => {
  it('reparte proporcional al peso', () => {
    expect(prorratearCargo(1000, { 1: 1, 2: 1 })).toEqual({ 1: 500, 2: 500 })
  })

  it('la suma de los repartos SIEMPRE da el monto exacto', () => {
    const r = prorratearCargo(1000, { 1: 1, 2: 1, 3: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(1000)
  })

  it('el residuo va a la linea de mayor peso', () => {
    // 100 / 3 partes desiguales: 1+1+4 = 6 → 16.67 + 16.67 + 66.66 = 100.00
    const r = prorratearCargo(100, { 1: 1, 2: 1, 3: 4 })
    expect(r[1]).toBe(16.67)
    expect(r[2]).toBe(16.67)
    expect(r[3]).toBe(66.66)
  })

  it('empate de peso maximo: desempata por menor id', () => {
    const r = prorratearCargo(100, { 7: 1, 3: 1, 5: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(100)
    expect(r[3]).toBe(33.34) // el residuo cae en el id menor
  })

  it('peso cero excluye la linea (es el mecanismo de alcance)', () => {
    const r = prorratearCargo(880, { 1: 0, 2: 0, 3: 1 })
    expect(r[3]).toBe(880)
    expect(r[1]).toBe(0)
  })

  it('monto negativo (bonificacion) reparte igual y suma exacto', () => {
    const r = prorratearCargo(-100, { 1: 1, 2: 1, 3: 1 })
    expect(Object.values(r).reduce((a, b) => a + b, 0)).toBe(-100)
  })

  it('suma de pesos cero devuelve vacio', () => {
    expect(prorratearCargo(1000, { 1: 0, 2: 0 })).toEqual({})
  })

  it('el flete real de la factura: 1.900.000 sobre 26 pallets', () => {
    const pesos = { 1: 0.5, 2: 0.5, 3: 2, 4: 0.5, 5: 0.5, 6: 1, 7: 1, 8: 2, 9: 1, 10: 2,
                    11: 4, 12: 1, 13: 1, 14: 2, 15: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1, 21: 1 }
    const r = prorratearCargo(1900000, pesos)
    expect(r[1]).toBe(36538.46)   // medio pallet
    expect(r[6]).toBe(73076.92)   // un pallet
    // Sumar 21 floats acumula error (da 1899999.9999999995). Cada parte es
    // exacta al centavo; el total hay que releerlo al centavo. En SQL no pasa:
    // numeric es decimal exacto y sum() da 1900000 clavado.
    expect(redondearSQL(Object.values(r).reduce((a, b) => a + b, 0), 2)).toBe(1900000)
  })
})
```

**Step 2: Correr y verificar que falla**

Run: `npx vitest run src/utils/prorrateoCompra.test.ts`
Expected: FAIL — el módulo no existe

**Step 3: Implementar**

```ts
import { redondearSQL } from './calculations'

/** Vector de pesos de un cargo: id de línea → peso. Peso 0 excluye la línea. */
export type PesosCargo = Record<number, number>

/**
 * Reparte un monto entre líneas según un vector de pesos.
 *
 * La suma de los repartos es EXACTAMENTE el monto: se redondea cada parte a 2
 * decimales y el residuo se asigna a la línea de mayor peso (desempate: menor
 * id). Sin esa regla, repartir sobre pesos fraccionarios no vuelve a sumar el
 * monto y el check de integridad COMPRA-A2 se pone rojo por centavos.
 *
 * Espejo exacto de prorratear_cargo() en SQL (mig 193). Si cambiás uno,
 * cambiá el otro y corré prorrateoCompra.espejo.test.ts.
 */
export function prorratearCargo(monto: number, pesos: PesosCargo): Record<number, number> {
  const entradas = Object.entries(pesos).map(([k, v]) => [Number(k), Number(v)] as const)
  const totalPeso = entradas.reduce((acc, [, p]) => acc + p, 0)
  if (totalPeso === 0) return {}

  const [idResiduo] = entradas.sort((a, b) => b[1] - a[1] || a[0] - b[0])[0]

  const salida: Record<number, number> = {}
  let acumulado = 0
  for (const [id, peso] of entradas) {
    if (id === idResiduo) continue
    const parte = redondearSQL(monto * peso / totalPeso, 2)
    salida[id] = parte
    acumulado += parte
  }
  salida[idResiduo] = redondearSQL(monto - acumulado, 2)
  return salida
}
```

**Contrato de entrada — el cero es un estado válido, el negativo y el `NaN` son corrupción.**

Sin esto la función acepta basura en silencio, y en un ERP donde el resultado se convierte en costo eso es peor que fallar. Casos verificados con la versión permisiva: `prorratearCargo(100, {1:1, 2:-1})` devuelve `{}` y **el cargo desaparece entero sin aviso**; `{1:NaN, 2:1}` redistribuye todo a la línea 2 sin que nadie se entere.

- Todos los pesos en cero → `{}`. Estado legítimo mientras el usuario llena la grilla.
- Un peso negativo o no finito → `throw`, nombrando la línea.
- `monto` no finito → `throw`. Nada de defensividad asimétrica entre monto y pesos.
- **No uses `Number(v) || 0`**: convertir `NaN` a `0` hace indistinguible un dato corrupto de una exclusión deliberada, porque `0` *es* el mecanismo de alcance.

Esta decisión define la firma de la RPC, así que tiene que estar tomada antes de la Task 9.

**Sobre el desempate:** el comparador `(a,b) => b[1]-a[1] || a[0]-b[0]` es un orden total sobre ids distintos, así que el resultado **no** depende del orden de iteración de `Object.entries`. En SQL alcanza con `ORDER BY peso DESC, id ASC LIMIT 1` para elegir la fila del residuo; la acumulación no necesita orden, porque `numeric` es exacto y la suma es asociativa.

**Step 4: Correr y verificar que pasa**

Run: `npx vitest run src/utils/prorrateoCompra.test.ts`
Expected: PASS (8 tests)

**Step 5: Commit**

```bash
git add src/utils/prorrateoCompra.ts src/utils/prorrateoCompra.test.ts && git commit -m "Repartir un cargo de compra sobre un vector de pesos"
```

---

### Task 3: Motor de costos de compra

**Files:**
- Modify: `src/utils/prorrateoCompra.ts`
- Test: `src/utils/prorrateoCompra.test.ts`

**Step 1: Escribir el test que falla**

Agregá al final del archivo de test:

```ts
import { calcularCostosCompra, type CargoCompra, type LineaCompra } from './prorrateoCompra'

describe('calcularCostosCompra', () => {
  const linea = (over: Partial<LineaCompra> = {}): LineaCompra => ({
    id: 1, cantidad: 10, costoUnitario: 100, bonificacion: 0,
    impuestosInternos: 0, porcentajeIva: 21, condicionIva: 'gravado', ...over,
  })
  const cargo = (over: Partial<CargoCompra> = {}): CargoCompra => ({
    id: 1, concepto: 'x', monto: 0, condicionIva: 'no_gravado', porcentajeIva: 0,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: {}, ...over,
  })

  it('sin cargos se comporta igual que hoy: neto x (1 + II%)', () => {
    const r = calcularCostosCompra([linea({ impuestosInternos: 8.6956 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBeCloseTo(108.6956, 4)
  })

  it('un cargo NO GRAVADO entra al costo pero NO a la base de IVA', () => {
    const r = calcularCostosCompra(
      [linea()],
      [cargo({ monto: 500, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].baseIvaUnitaria).toBe(100)      // 1000/10, sin el cargo
    expect(r.lineas[0].ivaUnitario).toBe(21)           // 21% de 100, NO de 150
    expect(r.lineas[0].cargosUnitarios).toBe(50)       // 500/10
    expect(r.lineas[0].costoRealUnitario).toBe(150)    // sí entra al costo
  })

  it('un cargo fuera de factura entra al costo pero no al IVA de la factura', () => {
    const r = calcularCostosCompra(
      [linea()],
      [cargo({ monto: 500, condicionIva: 'gravado', porcentajeIva: 21, enFactura: false, pesos: { 1: 1 } })],
      {}
    )
    expect(r.totales.baseIvaFactura).toBe(1000)   // el cargo no suma al IVA de esta compra
    expect(r.lineas[0].costoRealUnitario).toBe(150)
  })

  it('afectaBaseII=false: la bonificacion baja el IVA pero no el impuesto interno', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [cargo({ monto: -200, condicionIva: 'gravado', porcentajeIva: 21, afectaBaseII: false, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].baseIvaUnitaria).toBe(80)   // (1000-200)/10
    expect(r.lineas[0].iiUnitario).toBe(10)        // 10% de 1000/10, NO de 800/10
  })

  it('afectaBaseII=true: la bonificacion baja las dos bases', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [cargo({ monto: -200, condicionIva: 'gravado', porcentajeIva: 21, afectaBaseII: true, pesos: { 1: 1 } })],
      {}
    )
    expect(r.lineas[0].iiUnitario).toBe(8)         // 10% de 800/10
  })

  it('el factor de ajuste cuadra el II declarado y se reporta', () => {
    const r = calcularCostosCompra(
      [linea({ impuestosInternos: 10 })],
      [],
      { 10: 110 }   // declarado 110 vs calculado 100
    )
    expect(r.factorAjuste[10]).toBeCloseTo(1.1, 6)
    expect(r.lineas[0].iiUnitario).toBeCloseTo(11, 4)
  })

  it('cantidad 0 no explota', () => {
    const r = calcularCostosCompra([linea({ cantidad: 0 })], [], {})
    expect(r.lineas[0].costoRealUnitario).toBe(0)
  })
})
```

**Step 2: Correr y verificar que falla**

Run: `npx vitest run src/utils/prorrateoCompra.test.ts -t calcularCostosCompra`
Expected: FAIL — `calcularCostosCompra is not exported`

**Step 3: Implementar**

Agregá a `src/utils/prorrateoCompra.ts`:

```ts
import type { CondicionIva } from './condicionIva'

export interface LineaCompra {
  id: number
  cantidad: number
  costoUnitario: number
  bonificacion: number       // %
  impuestosInternos: number  // tasa efectiva %
  porcentajeIva: number      // %
  condicionIva: CondicionIva
}

export interface CargoCompra {
  id: number
  concepto: string
  monto: number              // SIN IVA. Negativo = bonificación
  condicionIva: CondicionIva
  porcentajeIva: number
  enFactura: boolean         // suma al cuadre contra el papel
  prorrateaAlCosto: boolean  // entra al costo unitario
  afectaBaseII: boolean
  pesos: PesosCargo
}

export interface CostosLinea {
  id: number
  baseIvaUnitaria: number
  iiUnitario: number
  cargosUnitarios: number
  ivaUnitario: number
  costoNetoUnitario: number
  costoRealUnitario: number
}

export interface CostosCompra {
  lineas: CostosLinea[]
  totales: { baseIvaFactura: number; iva: number; impuestosInternos: number; noGravado: number }
  /** tasa de II → declarado/calculado. 1 = cuadra solo. */
  factorAjuste: Record<number, number>
}

/**
 * Motor canónico de costos de una compra (espejo de la mig 193).
 *
 * Dos bases separadas a propósito:
 *   · baseIvaFactura → sólo cargos EN FACTURA. Alimenta compras.iva y el cuadre.
 *   · baseCosto      → todos los que prorratean. Alimenta costo_real_unitario.
 * El IVA de un flete de transportista inscripto es crédito fiscal: entra su
 * neto al costo, su IVA no entra a ningún lado de esta factura.
 *
 * @param iiDeclarado - tasa de II → monto declarado en la factura. Vacío = sin ajuste.
 */
export function calcularCostosCompra(
  lineas: LineaCompra[],
  cargos: CargoCompra[],
  iiDeclarado: Record<number, number>
): CostosCompra {
  const repartos = new Map<number, Record<number, number>>()
  for (const c of cargos) repartos.set(c.id, prorratearCargo(c.monto, c.pesos))
  const asignado = (c: CargoCompra, lineaId: number) => repartos.get(c.id)?.[lineaId] ?? 0

  const neto = (l: LineaCompra) => l.cantidad * l.costoUnitario * (1 - (l.bonificacion || 0) / 100)
  const suma = (l: LineaCompra, filtro: (c: CargoCompra) => boolean) =>
    cargos.filter(filtro).reduce((acc, c) => acc + asignado(c, l.id), 0)

  const gravado = (c: CargoCompra) => c.condicionIva === 'gravado'

  // Bases por línea, antes del ajuste de II
  const bases = lineas.map(l => ({
    linea: l,
    baseIvaFactura: neto(l) + suma(l, c => gravado(c) && c.enFactura),
    baseCosto: neto(l) + suma(l, c => gravado(c) && c.prorrateaAlCosto),
    baseII: neto(l) + suma(l, c => gravado(c) && c.afectaBaseII),
    noGravado: suma(l, c => !gravado(c) && c.prorrateaAlCosto),
  }))

  // Factor de ajuste por alícuota de II
  const factorAjuste: Record<number, number> = {}
  for (const [tasaStr, declarado] of Object.entries(iiDeclarado)) {
    const tasa = Number(tasaStr)
    const calculado = bases
      .filter(b => Math.abs(b.linea.impuestosInternos - tasa) < 1e-6)
      .reduce((acc, b) => acc + b.baseII * tasa / 100, 0)
    factorAjuste[tasa] = calculado ? declarado / calculado : 1
  }

  const salida = bases.map(b => {
    const { linea: l } = b
    const cant = l.cantidad || 0
    const factor = factorAjuste[l.impuestosInternos] ?? 1
    const ii = b.baseII * (l.impuestosInternos || 0) / 100 * factor
    const porUnidad = (v: number) => (cant > 0 ? v / cant : 0)
    return {
      id: l.id,
      baseIvaUnitaria: porUnidad(b.baseIvaFactura),
      iiUnitario: porUnidad(ii),
      cargosUnitarios: porUnidad(b.noGravado),
      ivaUnitario: porUnidad(b.baseIvaFactura * (l.condicionIva === 'gravado' ? l.porcentajeIva : 0) / 100),
      costoNetoUnitario: porUnidad(neto(l)),
      costoRealUnitario: porUnidad(b.baseCosto + ii + b.noGravado),
    }
  })

  return {
    lineas: salida,
    totales: {
      baseIvaFactura: bases.reduce((a, b) => a + b.baseIvaFactura, 0),
      iva: salida.reduce((a, s, i) => a + s.ivaUnitario * (lineas[i].cantidad || 0), 0),
      impuestosInternos: salida.reduce((a, s, i) => a + s.iiUnitario * (lineas[i].cantidad || 0), 0),
      noGravado: bases.reduce((a, b) => a + b.noGravado, 0),
    },
    factorAjuste,
  }
}
```

**Step 4: Correr y verificar que pasa**

Run: `npx vitest run src/utils/prorrateoCompra.test.ts`
Expected: PASS (16 tests)

**Step 5: Commit**

```bash
git add src/utils/prorrateoCompra.ts src/utils/prorrateoCompra.test.ts && git commit -m "Calcular el costo de una compra con cargos prorrateados"
```

---

### Task 4: Test golden contra la factura real

Este es el test que justifica todo el trabajo. Los números salen del Excel `CALCULO_FACTURA_A0005-00461415.xlsx`.

**Files:**
- Create: `src/utils/prorrateoCompra.golden.test.ts`

**Step 1: Escribir el test**

```ts
import { describe, it, expect } from 'vitest'
import { calcularCostosCompra, type CargoCompra, type LineaCompra } from './prorrateoCompra'

// Fixture: factura A0005-00461415 de Manaos, 21 renglones, 13,3 M.
// Es el caso que motivó este rediseño. El Excel del gerente cuadra el impuesto
// interno con un factor manual de 1,0496; acá tiene que dar 1,0000.

const ITEMS: LineaCompra[] = [
  { id: 1,  cantidad: 60,  costoUnitario: 4793.61, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 2,  cantidad: 60,  costoUnitario: 4793.61, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 3,  cantidad: 120, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 4,  cantidad: 75,  costoUnitario: 3994.67, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 5,  cantidad: 75,  costoUnitario: 3994.67, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 6,  cantidad: 120, costoUnitario: 2972.04, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 7,  cantidad: 80,  costoUnitario: 2316.91, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 8,  cantidad: 280, costoUnitario: 2197.07, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 9,  cantidad: 120, costoUnitario: 4626.22, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 10, cantidad: 150, costoUnitario: 5123.97, bonificacion: 0.6, impuestosInternos: 0,      porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 11, cantidad: 240, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 12, cantidad: 60,  costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 13, cantidad: 60,  costoUnitario: 5992.01, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 14, cantidad: 120, costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 15, cantidad: 60,  costoUnitario: 5782.77, bonificacion: 0.6, impuestosInternos: 8.6956, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 16, cantidad: 115, costoUnitario: 8347.11, bonificacion: 0.6, impuestosInternos: 0,      porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 17, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 18, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 19, cantidad: 140, costoUnitario: 3822.90, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 20, cantidad: 120, costoUnitario: 2796.27, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
  { id: 21, cantidad: 168, costoUnitario: 1030.63, bonificacion: 0.6, impuestosInternos: 4.1667, porcentajeIva: 21, condicionIva: 'gravado' },
]

const neto = (id: number) => {
  const l = ITEMS.find(x => x.id === id)!
  return l.cantidad * l.costoUnitario * (1 - l.bonificacion / 100)
}
const pesosPorMonto = (ids: number[]) => Object.fromEntries(ids.map(id => [id, neto(id)]))

const PALLETS_FLETE: Record<number, number> = { 1: .5, 2: .5, 3: 2, 4: .5, 5: .5, 6: 1, 7: 1, 8: 2, 9: 1, 10: 2, 11: 4, 12: 1, 13: 1, 14: 2, 15: 1, 16: 1, 17: 1, 18: 1, 19: 1, 20: 1, 21: 1 }
const PALLETS:       Record<number, number> = { ...PALLETS_FLETE, 4: 1, 5: 1 }

const CARGOS: CargoCompra[] = [
  { id: 1, concepto: 'Flete y descarga', monto: 1_900_000, condicionIva: 'no_gravado', porcentajeIva: 0,
    enFactura: false, prorrateaAlCosto: true, afectaBaseII: false, pesos: PALLETS_FLETE },
  { id: 2, concepto: 'Pallets x 9 tacos', monto: 162_000, condicionIva: 'no_gravado', porcentajeIva: 0,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: PALLETS },
  { id: 3, concepto: 'Separadores bidon', monto: 8_800, condicionIva: 'no_gravado', porcentajeIva: 0,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: { 21: 1 } },
  // Descuento de precio: SI baja la base del impuesto interno
  { id: 4, concepto: 'Bonif. promo COLA 3.00', monto: -103_465.32, condicionIva: 'gravado', porcentajeIva: 21,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: true, pesos: pesosPorMonto([3, 11]) },
  // Bonificacion comercial: NO baja la base del impuesto interno. Este flag es
  // TODO el descubrimiento: sin el, el II no cuadra por casi 5%.
  { id: 5, concepto: 'Bonif. promo 3000cc', monto: -203_318.28, condicionIva: 'gravado', porcentajeIva: 21,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: false, pesos: pesosPorMonto([3, 11, 12, 13, 14, 15]) },
  { id: 6, concepto: 'Redondeo', monto: -0.49, condicionIva: 'gravado', porcentajeIva: 21,
    enFactura: true, prorrateaAlCosto: true, afectaBaseII: true, pesos: pesosPorMonto(ITEMS.map(i => i.id)) },
]

const II_DECLARADO = { 8.6956: 338_884.46, 4.1667: 199_027.21 }

describe('Factura A0005-00461415 (caso testigo del rediseno)', () => {
  const r = calcularCostosCompra(ITEMS, CARGOS, II_DECLARADO)

  it('el impuesto interno cuadra SOLO: factor de ajuste = 1', () => {
    // El Excel del gerente necesita 1,0496 acá. Modelando afectaBaseII, da 1.
    expect(r.factorAjuste[8.6956]).toBeCloseTo(1, 5)
    expect(r.factorAjuste[4.1667]).toBeCloseTo(1, 5)
  })

  it('el impuesto interno total coincide con lo declarado en la factura', () => {
    expect(r.totales.impuestosInternos).toBeCloseTo(338_884.46 + 199_027.21, 1)
  })

  it('el costo total sin IVA coincide con el Excel al centavo', () => {
    const total = r.lineas.reduce(
      (acc, l, i) => acc + l.costoRealUnitario * ITEMS[i].cantidad, 0)
    expect(total).toBeCloseTo(12_797_344.26, 1)
  })

  it('los cargos no gravados no inflan la base de IVA', () => {
    // Si el flete entrara a la base, el IVA se calcularia sobre 2.070.800 de mas
    expect(r.totales.baseIvaFactura).toBeCloseTo(12_797_344.26 - 2_070_800 - r.totales.impuestosInternos, 0)
  })

  it('MANAOS LIMA LIMON 600cc: desglose completo por pack', () => {
    const l = r.lineas.find(x => x.id === 1)!
    expect(l.baseIvaUnitaria).toBeCloseTo(4764.85, 2)
    expect(l.iiUnitario).toBeCloseTo(198.54, 2)
    expect(l.cargosUnitarios).toBeCloseTo(658.97, 2)   // flete + pallets
    expect(l.ivaUnitario).toBeCloseTo(1000.62, 2)
    expect(l.costoRealUnitario).toBeCloseTo(5622.36, 2)
  })

  it('los separadores caen 100% en el bidon y en ningun otro producto', () => {
    const bidon = r.lineas.find(x => x.id === 21)!
    const otra = r.lineas.find(x => x.id === 1)!
    // bidon: flete 73076.92 + pallets 6000 + separadores 8800 = 87876.92 / 168
    expect(bidon.cargosUnitarios).toBeCloseTo(523.08, 2)
    // linea 1: solo flete 36538.46 + pallets 3000, sin separadores
    expect(otra.cargosUnitarios).toBeCloseTo(658.97, 2)
  })

  it('el modelo NO copia el reparto de II del Excel: lo corrige', () => {
    // El factor proporcional del Excel unta el II de la promo sobre productos
    // que no participaron. MANAOS COLA 600cc (id 9) no tuvo promo: el Excel le
    // carga 419,70 por pack, el modelo 399,86.
    const sinPromo = r.lineas.find(x => x.id === 9)!
    expect(sinPromo.iiUnitario).toBeCloseTo(399.86, 1)
    expect(sinPromo.iiUnitario).toBeLessThan(419.70)
  })
})
```

**Step 2: Correr**

Run: `npx vitest run src/utils/prorrateoCompra.golden.test.ts`
Expected: PASS (8 tests). **Si alguno falla, el motor está mal — no toques el test para que pase.** Los números vienen de una factura real verificada.

**Step 3: Commit**

```bash
git add src/utils/prorrateoCompra.golden.test.ts && git commit -m "Atar el motor de costos a la factura real de Manaos"
```

---

## Ensayar una migración sin aplicarla

Antes de dar por buena cualquier migración de esta fase, **corrėla entera contra producción dentro de un bloque que termine lanzando una excepción**. La excepción garantiza el rollback, así que el esquema real valida sintaxis y semántica sin que quede nada aplicado:

```sql
DO $dry$
DECLARE v_res text;
BEGIN
  -- ...toda la DDL / las funciones de la migración...

  SELECT format('tablas=%s policies=%s fks=%s', ...) INTO v_res;
  RAISE EXCEPTION 'ENSAYO OK >>> %', v_res;   -- fuerza el rollback y devuelve la verificación
END $dry$;
```

El resultado vuelve como el mensaje de error. Verificado que el rollback es real: un `CREATE TABLE` de prueba no sobrevive.

Sirve además para probar que un CHECK **muerde**: insertá adentro del ensayo la fila que debería rechazar y confirmá que falla. Sin esto, la primera prueba de sintaxis de una migración es el momento de aplicarla a prod, que es el peor momento posible. Se descubrió al escribir la Task 5, cuando el implementador avisó que su SQL no se había ejecutado en ningún lado.

Las funciones de las tasks 6-8 se pueden ensayar igual: `CREATE OR REPLACE FUNCTION` adentro del bloque, llamarla con los datos de la factura testigo, comparar contra el golden de TS, y `RAISE EXCEPTION` con el resultado.

## Fase 2 — Migraciones 192, 193 y 194

**Van en tres archivos, no en uno.** El plan original metía todo en la 192 y estaba mal: ese archivo termina en `COMMIT;` seguido de un bloque de verificación comentado, así que appendear las funciones al final las dejaba **fuera de la transacción** — justo lo que el `BEGIN`/`COMMIT` estaba evitando. Una falla a mitad de camino habría dejado tablas creadas con RPCs a medias.

- **190** — tablas, índices, RLS, columna `cargos_unitarios` (Task 5)
- **191** — funciones puras: `prorratear_cargo`, `calcular_costos_compra`, `costo_real_unitario` (Tasks 6-8)
- **192** — RPCs y el check de integridad (Tasks 9-12)

De paso el ledger queda más legible y cada parte se puede aplicar y verificar sola.

**Antes de escribir SQL:** leé `migrations/MANIFEST.md` y mirá cómo la mig 177 y la 178 parchean funciones leyendo el catálogo en vez de hardcodear el cuerpo. Seguí ese patrón.

**Cómo aplicar y probar:** usá una branch de Supabase (`create_branch`), aplicá ahí, verificá, y recién después a producción. No apliques directo a prod.

### Task 5: Tablas, índices y RLS

**Files:**
- Create: `migrations/192_compra_cargos_prorrateo.sql`

**Step 1: Escribir la primera parte de la migración**

```sql
-- ============================================================================
-- 192 · Compras: cargos prorrateados y cuadre fiscal
-- ============================================================================
-- Ver docs/plans/2026-08-18-cargos-y-cuadre-de-compras-design.md
--
-- Tres cosas que la carga de compras no sabía representar:
--   · flete, pallets y separadores (el 16,2% del costo de la factura testigo)
--   · que el reparto es por volumen, no por monto, y a veces sólo a un subconjunto
--   · que NO toda bonificación baja la base del impuesto interno
--
-- El "alcance" no es un concepto: un peso 0 excluye la línea. Y una bonificación
-- es un cargo de monto negativo. Por eso alcanza con una sola tabla.
--
-- Forward-only: las compras existentes no tienen cargos ⇒ Σ cargos = 0 ⇒ el
-- costo es idéntico al de hoy. Cero backfill.
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.compra_cargos (
  id                 bigserial PRIMARY KEY,
  compra_id          bigint NOT NULL REFERENCES public.compras(id) ON DELETE CASCADE,
  sucursal_id        bigint NOT NULL REFERENCES public.sucursales(id),
  orden              integer NOT NULL DEFAULT 0,
  concepto           text    NOT NULL,
  monto              numeric(12,2) NOT NULL,
  condicion_iva      text    NOT NULL DEFAULT 'no_gravado'
                       CHECK (condicion_iva IN ('gravado','exento','no_gravado')),
  en_factura         boolean NOT NULL DEFAULT true,
  prorratea_al_costo boolean NOT NULL DEFAULT true,
  afecta_base_ii     boolean NOT NULL DEFAULT false,
  base_prorrateo     text    NOT NULL DEFAULT 'unidades'
                       CHECK (base_prorrateo IN ('monto','cantidad','unidades')),
  created_at         timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE public.compra_cargos IS
  'Conceptos de una compra que no son renglones de producto: flete, pallets, separadores, bonificaciones promocionales, redondeo. Monto negativo = bonificación.';
COMMENT ON COLUMN public.compra_cargos.monto IS
  'SIN IVA. Negativo = bonificación.';
COMMENT ON COLUMN public.compra_cargos.en_factura IS
  'true = el concepto viene impreso en la factura y suma al cuadre. El flete de un tercero va en false: no toca compras.total ni compras.iva, pero sí el costo.';
COMMENT ON COLUMN public.compra_cargos.prorratea_al_costo IS
  'true = entra al costo unitario de los productos. Independiente de en_factura.';
COMMENT ON COLUMN public.compra_cargos.afecta_base_ii IS
  'true = el cargo modifica la base de cálculo de impuestos internos. Una bonificación comercial NO la modifica; un descuento de precio SI. Es la causa del descuadre histórico del II.';
COMMENT ON COLUMN public.compra_cargos.base_prorrateo IS
  'Sólo pre-llena el vector de pesos en la UI. La verdad siempre es compra_cargo_repartos.';
COMMENT ON COLUMN public.compra_cargos.condicion_iva IS
  'Un cargo gravado tributa a la alícuota de las líneas sobre las que se prorratea: no lleva alícuota propia. Hoy los 247 productos son 21%, así que la distinción no se plantea. Si alguna vez conviven alícuotas distintas en una misma compra hay que decidir qué significa la base gravada de una línea que recibe un cargo de otra alícuota.';

CREATE TABLE IF NOT EXISTS public.compra_cargo_repartos (
  cargo_id       bigint NOT NULL REFERENCES public.compra_cargos(id) ON DELETE CASCADE,
  compra_item_id bigint NOT NULL REFERENCES public.compra_items(id) ON DELETE CASCADE,
  peso           numeric(12,4) NOT NULL DEFAULT 0,
  PRIMARY KEY (cargo_id, compra_item_id)
);

COMMENT ON TABLE public.compra_cargo_repartos IS
  'Vector de pesos de un cargo. Peso 0 excluye la línea: por eso el "alcance" no existe como concepto aparte.';

CREATE INDEX IF NOT EXISTS idx_compra_cargos_compra ON public.compra_cargos(compra_id);

ALTER TABLE public.compra_cargos          ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.compra_cargo_repartos  ENABLE ROW LEVEL SECURITY;

-- RLS espejo de compra_items: admin escribe, admin y depósito leen, siempre
-- acotado a la sucursal activa.
DROP POLICY IF EXISTS mt_compra_cargos_select ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_select ON public.compra_cargos FOR SELECT TO authenticated
  USING ((es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
         AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_compra_cargos_insert ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_insert ON public.compra_cargos FOR INSERT TO authenticated
  WITH CHECK ((es_admin() OR EXISTS (SELECT 1 FROM perfiles WHERE perfiles.id = auth.uid() AND perfiles.rol = 'deposito'))
              AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_compra_cargos_update ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_update ON public.compra_cargos FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_compra_cargos_delete ON public.compra_cargos;
CREATE POLICY mt_compra_cargos_delete ON public.compra_cargos FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

-- Los repartos heredan el permiso de su cargo.
DROP POLICY IF EXISTS mt_compra_cargo_repartos_all ON public.compra_cargo_repartos;
CREATE POLICY mt_compra_cargo_repartos_all ON public.compra_cargo_repartos FOR ALL TO authenticated
  USING (EXISTS (SELECT 1 FROM compra_cargos c WHERE c.id = cargo_id AND c.sucursal_id = current_sucursal_id()))
  WITH CHECK (EXISTS (SELECT 1 FROM compra_cargos c WHERE c.id = cargo_id AND c.sucursal_id = current_sucursal_id()));

-- Snapshot por línea: sin esto no se puede reconstruir cuánto fue flete y
-- cuánto impuesto interno al reabrir la compra.
ALTER TABLE public.compra_items
  ADD COLUMN IF NOT EXISTS cargos_unitarios numeric(12,4) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.compra_items.cargos_unitarios IS
  'Cargos no gravados prorrateados a esta línea, por unidad (mig 192). Ya está incluido en costo_real_unitario.';
```

**Step 2: Verificar la sintaxis sin aplicar**

Antes de aplicar, confirmá que `sucursales` y `current_sucursal_id()` existen con esos nombres:

```sql
SELECT to_regclass('public.sucursales'), pg_get_functiondef('public.current_sucursal_id'::regproc) IS NOT NULL;
```

**Step 3: Commit** (todavía sin aplicar)

```bash
git add migrations/192_compra_cargos_prorrateo.sql && git commit -m "Crear las tablas de cargos de compra con su RLS"
```

---

### Task 6: Función de prorrateo en SQL

**Files:**
- Create o Modify: `migrations/193_compra_cargos_funciones.sql`

**Step 1: Agregar la función**

```sql
-- ----------------------------------------------------------------------------
-- Reparto de un cargo sobre un vector de pesos.
-- Espejo EXACTO de prorratearCargo() en src/utils/prorrateoCompra.ts.
-- El residuo va a la línea de mayor peso (desempate: menor id) para que la suma
-- dé el monto exacto: sin eso, COMPRA-A2 se pone rojo por centavos.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.prorratear_cargo(p_monto numeric, p_pesos jsonb)
RETURNS TABLE(item_id bigint, monto numeric)
LANGUAGE plpgsql IMMUTABLE AS $fn$
DECLARE
  v_total_peso numeric;
  v_id_residuo bigint;
  v_acumulado  numeric := 0;
  v_rec        RECORD;
BEGIN
  SELECT sum(value::numeric) INTO v_total_peso FROM jsonb_each_text(p_pesos);
  IF v_total_peso IS NULL OR v_total_peso = 0 THEN RETURN; END IF;

  SELECT key::bigint INTO v_id_residuo
    FROM jsonb_each_text(p_pesos)
   ORDER BY value::numeric DESC, key::bigint ASC
   LIMIT 1;

  FOR v_rec IN
    SELECT key::bigint AS id, round(p_monto * value::numeric / v_total_peso, 2) AS parte
      FROM jsonb_each_text(p_pesos)
     WHERE key::bigint <> v_id_residuo
     ORDER BY key::bigint
  LOOP
    v_acumulado := v_acumulado + v_rec.parte;
    item_id := v_rec.id;  monto := v_rec.parte;  RETURN NEXT;
  END LOOP;

  item_id := v_id_residuo;  monto := round(p_monto - v_acumulado, 2);  RETURN NEXT;
END;
$fn$;
```

**Step 2: Verificar el espejo contra el test de TS**

Aplicá en una branch y corré exactamente los casos del test de Task 2:

```sql
-- debe dar 16.67 / 16.67 / 66.66, suma exacta 100
SELECT item_id, monto FROM prorratear_cargo(100, '{"1":1,"2":1,"3":4}'::jsonb) ORDER BY item_id;
-- debe dar suma exacta -100
SELECT sum(monto) FROM prorratear_cargo(-100, '{"1":1,"2":1,"3":1}'::jsonb);
-- el flete real: 36538.46 en medio pallet, 73076.92 en uno, suma 1900000
SELECT sum(monto) FROM prorratear_cargo(1900000, '{"1":0.5,"2":0.5,"3":2,"4":0.5,"5":0.5,"6":1,"7":1,"8":2,"9":1,"10":2,"11":4,"12":1,"13":1,"14":2,"15":1,"16":1,"17":1,"18":1,"19":1,"20":1,"21":1}'::jsonb);
```

Expected: los tres resultados idénticos a los del test de TypeScript.

**Step 3: Commit**

```bash
git add migrations/193_compra_cargos_funciones.sql && git commit -m "Repartir un cargo en SQL con la misma regla de residuo que el front"
```

---

### Task 7: Reemplazar `costo_real_unitario`

**Files:**
- Create o Modify: `migrations/193_compra_cargos_funciones.sql`

El cuerpo actual (verificado en prod):

```sql
SELECT CASE
  WHEN p_tipo_factura = 'ZZ' THEN p_costo_neto
  ELSE round(p_costo_neto * (1 + COALESCE(p_pct_ii, 0) / 100), 4)
END;
```

**Step 1: Agregar el reemplazo**

```sql
-- ----------------------------------------------------------------------------
-- costo_real_unitario gana un término ADITIVO para los cargos prorrateados.
--
-- Se DROPEA la de 3 argumentos en vez de dejarla junto a una de 4 con DEFAULT:
-- dos sobrecargas con rangos de aridad superpuestos dan PGRST203 en runtime,
-- invisible para tsc y para los tests (trampa de la mig 176).
-- ----------------------------------------------------------------------------
DROP FUNCTION IF EXISTS public.costo_real_unitario(numeric, numeric, text);

CREATE OR REPLACE FUNCTION public.costo_real_unitario(
  p_costo_neto     numeric,
  p_pct_ii         numeric,
  p_tipo_factura   text,
  p_cargo_unitario numeric
) RETURNS numeric LANGUAGE sql IMMUTABLE AS $fn$
  SELECT CASE
    WHEN p_tipo_factura = 'ZZ' THEN round(p_costo_neto + COALESCE(p_cargo_unitario, 0), 4)
    ELSE round(p_costo_neto * (1 + COALESCE(p_pct_ii, 0) / 100)
               + COALESCE(p_cargo_unitario, 0), 4)
  END;
$fn$;

COMMENT ON FUNCTION public.costo_real_unitario(numeric,numeric,text,numeric) IS
  'Costo real por unidad (mig 192): neto × (1+II%) + cargos prorrateados. El IVA y las percepciones son crédito fiscal, no costo. ZZ = lo pagado.';
```

**Step 2: Actualizar los llamadores en la misma migración**

Son **tres**, no cuatro: `registrar_compra_completa`, `actualizar_compra_items` y `anular_compra_atomica`. `cambiar_proveedor_compra` menciona `costo_real_unitario` dos veces pero **no la llama** — son referencias a la columna homónima de `compra_items`. Y está bien que así sea: esa RPC clona la compra copiando la columna guardada, que es justo lo que promete. Contá las llamadas con el paréntesis (`costo_real_unitario(`), no con el nombre pelado, o vas a parchear una función que no la usa. En esta task sólo hay que hacer que **compilen** con el nuevo 4º argumento pasando `0`; la lógica de cargos entra en las tasks siguientes.

Usá el patrón de las migs 177/178: leer el cuerpo con `pg_get_functiondef`, reemplazar el ancla exacta exigiendo que aparezca una sola vez, y fallar si el cuerpo derivó. **No copies el cuerpo completo al archivo de migración.**

Verificá primero cuál es el ancla real en cada función:

```sql
SELECT p.proname, substring(p.prosrc from position('costo_real_unitario' in p.prosrc) - 40 for 140)
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.prosrc ILIKE '%costo_real_unitario%' AND p.proname <> 'costo_real_unitario';
```

**En ZZ el cargo TAMBIÉN suma.** La regla, que va en el `COMMENT` de la función:

> `tipo_factura` decide si se agregan **impuestos** encima, no si se ignoran **costos**.

En ZZ lo pagado ya incluye IVA e impuestos internos y por eso no se le suma nada de eso — son impuestos de esa misma operación, ya adentro del precio. Pero un flete que factura un transportista aparte no está adentro de ese precio: es plata que salió igual. Que la mercadería haya venido con factura o sin ella no cambia que el camión se pagó.

No es un caso de borde: **ZZ es el 47,9% de las compras activas** (58 de 121). Si la rama ZZ descartara el cargo, el flete y los pallets de la mitad de las compras se evaporarían sin aviso en cuanto la Task 9 empiece a pasar cargos reales.

La misma decisión aplica al espejo `calcularCostoReal` de `src/utils/calculations.ts:145`, que hoy tiene 3 parámetros y necesita el cuarto (Task 9).

**Step 3: Aplicar en branch y verificar que no quedó ambigüedad**

```sql
SELECT proname, pronargs FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND proname = 'costo_real_unitario';
```
Expected: **una sola fila**, `pronargs = 4`.

**Step 4: Commit**

```bash
git add migrations/193_compra_cargos_funciones.sql && git commit -m "Sumar los cargos al costo real canonico sin dejar sobrecarga ambigua"
```

---

### Task 8: Espejo SQL del motor de costos

**Files:**
- Create o Modify: `migrations/193_compra_cargos_funciones.sql`

**Step 1: Escribir `calcular_costos_compra`**

Función que recibe `p_items jsonb`, `p_cargos jsonb` (cada cargo con su `pesos`) y `p_ii_declarado jsonb`, y devuelve por línea: `base_iva`, `ii`, `cargos`, `costo_neto`, `costo_real` (todos unitarios) más el `factor_ajuste` por alícuota.

Es la traducción literal de `calcularCostosCompra` de Task 3. Mantené los mismos nombres de concepto (`base_iva_factura`, `base_costo`, `base_ii`) para que el espejo se lea.

Puntos donde es fácil equivocarse (todos salieron de bugs reales encontrados en la versión de TS):

- `base_costo` incluye **sólo los cargos gravados** con `prorratea_al_costo`. Los no gravados van aparte y se suman recién en el costo final. Si los metés también en `base_costo` **los contás dos veces**.
- `base_costo` filtra por `prorratea_al_costo`, `base_iva_factura` por `en_factura`. Son filtros distintos a propósito.
- El IVA se calcula sobre `base_iva_factura`, nunca sobre `base_costo`.
- **`base_iva_factura` incluye sólo las líneas `gravado`.** Sumar el neto de las exentas y no gravadas la vuelve "neto de la factura" y deja de cuadrar contra el papel.
- **Normalizá la tasa de II con `round(tasa, 4)` en las DOS puntas** — al agrupar el denominador y al buscar el factor. Nada de tolerancia en una y clave exacta en la otra: una línea que entra al denominador por tolerancia pero no matchea exacto se lleva factor 1 y el total deja de cuadrar. En prod ya conviven `4.1667` y `4.1700` (alguien tipeó 4,17), así que el caso es real. Que queden en buckets distintos **es lo correcto**: si la factura declara un solo bucket y hay una línea en 4,17, el cuadre tiene que avisar.
- Son **dos** totales de no gravado, no uno: los cargos `en_factura` (van a `compras.no_gravado` y al cuadre) y los que `prorratea_al_costo` (reconcilian contra la suma de los unitarios). Un cargo en factura que no prorratea desaparece si los mezclás.
- `cantidad = 0` ⇒ todo unitario es 0, no división.
- El factor de ajuste se calcula **antes** de imputar el II a las líneas.

**Step 2: Verificar contra el golden test**

Aplicá en branch, cargá el fixture de la factura A0005-00461415 y comprobá:

```sql
-- costo total sin IVA = 12797344.26 (±0,05)
-- factor de ajuste = 1.000000 en ambas alícuotas
-- linea 1 (MANAOS LIMA LIMON 600): base_iva 4764.85 · ii 198.54 · cargos 658.97 · costo_real 5622.36
```

Expected: idéntico al test de TypeScript de Task 4. **Si difieren, hay un bug — no ajustes ninguno de los dos "para que coincidan": encontrá cuál está mal.**

**Step 3: Commit**

```bash
git add migrations/193_compra_cargos_funciones.sql && git commit -m "Calcular los costos de la compra dentro de la base"
```

---

### Task 9: `registrar_compra_completa` acepta cargos

**Files:**
- Create o Modify: `migrations/194_compra_cargos_rpcs.sql`

**Step 1: Extender la firma**

Nuevo parámetro `p_cargos jsonb DEFAULT '[]'::jsonb` **al final**. Con `DEFAULT` y siendo el único agregado, un cliente viejo sigue funcionando igual (manda 17 args, la nueva tiene 18 con default). Verificá que no queden dos sobrecargas: si la firma vieja sigue existiendo, dropeala.

Dentro de la función, después de insertar los `compra_items` (que es cuando existen los ids):

1. Insertar los cargos en `compra_cargos` con la `sucursal_id` de la compra.
2. Resolver los pesos: el payload los trae por **índice del array `p_items`**, no por id (los ids no existen todavía). Mapear índice → `compra_item_id`.
3. Insertar `compra_cargo_repartos`.
4. Llamar a `calcular_costos_compra` y usar su resultado para `costo_neto_unitario`, `cargos_unitarios` y `costo_real_unitario` de cada ítem.
5. Recalcular el costo promedio con el `costo_real` nuevo.

**Validaciones que deben fallar la transacción:**
- Un cargo con `prorratea_al_costo = true` y suma de pesos 0 → `RAISE EXCEPTION 'El cargo "%" no tiene ninguna línea asignada', concepto`.
- Un peso que apunta a un índice inexistente → excepción.

**Step 2: Verificar que una compra sin cargos da idéntico a antes**

En la branch, registrá una compra sin `p_cargos` y comprobá que `costo_real_unitario` es el mismo valor que daba antes de la migración. Es la garantía del forward-only.

**Step 3: Commit**

```bash
git add migrations/194_compra_cargos_rpcs.sql && git commit -m "Registrar una compra con sus cargos prorrateados"
```

---

### Task 10: `actualizar_compra_items` — el guard contra el borrado silencioso

**Files:**
- Create o Modify: `migrations/194_compra_cargos_rpcs.sql`

Esta es la task de mayor riesgo del plan. `actualizar_compra_items` hace `DELETE FROM compra_items`, lo que por CASCADE borra los `compra_cargo_repartos`. Si la RPC no recibe cargos, la compra queda con cargos sin destino: el costo pierde el 16% y `COMPRA-A2` se pone rojo sin que nadie haya tocado nada.

**Step 1: Extender la firma con `p_cargos jsonb DEFAULT NULL`**

Ojo con el `NULL` en vez de `'[]'`: hay que poder distinguir "no me mandaron cargos" de "me mandaron una lista vacía".

**Step 2: Implementar el guard**

```sql
-- Un cliente con chunk viejo del PWA editando una compra con cargos borraría
-- los repartos en silencio (el DELETE de compra_items cascadea). Falla explícito.
IF p_cargos IS NULL AND EXISTS (SELECT 1 FROM compra_cargos WHERE compra_id = p_compra_id) THEN
  RETURN jsonb_build_object('success', false, 'error',
    'Esta compra tiene cargos prorrateados. Actualizá la aplicación (recargá la página) antes de editarla.');
END IF;
```

**Step 3: Reescribir cargos y repartos**

Cuando `p_cargos` no es NULL: borrar los cargos de la compra e insertarlos de nuevo junto con sus repartos, mapeando por índice contra los `compra_items` recién creados. Después, recalcular costos igual que en Task 9.

**Step 4: Test manual del guard**

En la branch: creá una compra con cargos, después llamá a `actualizar_compra_items` **sin** `p_cargos`.
Expected: `{"success": false, "error": "Esta compra tiene cargos..."}`, y los cargos siguen intactos.

Repetí con una compra **sin** cargos y sin `p_cargos`.
Expected: `success: true` — el camino viejo sigue funcionando.

**Step 5: Commit**

```bash
git add migrations/194_compra_cargos_rpcs.sql && git commit -m "Que editar una compra no borre sus cargos en silencio"
```

---

### Task 11: `cambiar_proveedor_compra` clona los cargos

**Files:**
- Create o Modify: `migrations/194_compra_cargos_rpcs.sql`

La función anula la compra y la clona con otro proveedor. Si no clona los cargos, la compra nueva pierde el 16% del costo.

**Step 1:** Después del `INSERT INTO compra_items` de la clonación, copiar `compra_cargos` y `compra_cargo_repartos`, mapeando los `compra_item_id` viejos a los nuevos.

**Step 2: Verificar en branch** que el costo real de cada producto es idéntico antes y después de cambiar el proveedor.

**Step 3: Commit**

```bash
git add migrations/194_compra_cargos_rpcs.sql && git commit -m "Clonar los cargos al cambiar el proveedor de una compra"
```

---

### Task 12: Check de integridad `COMPRA-A2`

**Files:**
- Create o Modify: `migrations/194_compra_cargos_rpcs.sql`

**Step 1: Agregar el check a `auditoria_integridad()`**

Seguí el patrón exacto de la mig 178: leer el cuerpo con `pg_get_functiondef`, insertar la fila nueva junto a la de `COMPRA-A1`, exigir que el ancla aparezca una sola vez, ser idempotente.

```sql
('COMPRA-A2','high','sum(compra_cargo_repartos) = compra_cargos.monto (mig 192)',
  (SELECT count(*) FROM compra_cargos c
    WHERE c.prorratea_al_costo
      AND abs(COALESCE((SELECT sum(peso) FROM compra_cargo_repartos r WHERE r.cargo_id = c.id), 0)) > 0
      AND abs(c.monto - COALESCE((SELECT sum(peso) FROM compra_cargo_repartos r WHERE r.cargo_id = c.id), 0)) > 1.0)),
```

**Cuidado:** el check de arriba compara el monto contra la suma de *pesos*, que no es lo mismo. Lo correcto es comparar contra la suma de los *repartos calculados*. Definí bien qué guardás: si guardás sólo pesos, el check tiene que llamar a `prorratear_cargo` y sumar su salida. Resolvelo antes de escribirlo.

**Step 2: Verificar que arranca en verde**

```sql
SELECT * FROM auditoria_integridad() WHERE check_id IN ('COMPRA-A1','COMPRA-A2');
```
Expected: ambos en 0 violaciones. Si `COMPRA-A2` nace rojo, el gate diario de `.github/workflows/integridad.yml` queda inútil.

**Step 3: Correr el gate local**

Run: `node scripts/check-integridad.mjs`
Expected: exit 0

**Step 4: Commit**

```bash
git add migrations/194_compra_cargos_rpcs.sql && git commit -m "Vigilar que los cargos siempre cierren contra lo repartido"
```

---

### Task 13: Aplicar a producción

Son **tres** migraciones, y se aplican en orden: `192` (tablas), `193` (funciones), `194` (RPCs y el check). Si una falla, las siguientes no van.

**Step 1:** Ensayar las tres, cada una con el bloque `DO` que termina en `RAISE EXCEPTION` (ver arriba). La 193 y la 194 se ensayan **encima** de la 192 dentro del mismo bloque, porque dependen de sus tablas.

**Step 2:** Aplicar con `apply_migration`, una por una, verificando entre cada dos.

**Ojo con el `BEGIN;`/`COMMIT;` explícito** de los archivos: es estilo de la casa (42 de 197 archivos, incluida la 155, que se aplicó bien), pero `apply_migration` envuelve en su propia transacción, así que el `COMMIT` del archivo cierra la externa antes de tiempo. Si el ensayo pasa y el `apply_migration` se comporta raro, ése es el primer sospechoso.

**Step 3:** Verificar en prod:

```sql
SELECT proname, pronargs FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
 WHERE n.nspname='public' AND proname='costo_real_unitario';           -- 1 fila, 4 args
SELECT * FROM auditoria_integridad() WHERE severidad IN ('critical','high') AND violaciones > 0;  -- vacío
SELECT count(*) FROM compras WHERE estado<>'cancelada';                -- sigue 121
```

**Step 4:** Actualizar `migrations/MANIFEST.md` y correr `npm run check:migrations`.

**Step 5: Commit**

```bash
git add migrations/MANIFEST.md && git commit -m "Registrar las migs 192-194 en el manifiesto"
```

---

## Fase 3 — Modal de compras

### Task 14: Tipos y estado del reducer

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx`

Agregar al estado: `cargos: CargoCompraForm[]` y `iiDeclarado: Record<number, number>`. Las acciones: `AGREGAR_CARGO`, `ACTUALIZAR_CARGO`, `ELIMINAR_CARGO`, `SET_PESO_CARGO`, `SET_II_DECLARADO`, `TRAER_CARGOS_PROVEEDOR`.

Regla de pre-llenado al agregar un cargo o al cambiar `base_prorrateo`: `monto` → peso = neto de la línea; `cantidad` → peso = cantidad; `unidades` → peso = 1 en todas. Al agregar o quitar una línea de producto, el peso de la línea nueva se pre-llena con la misma regla; los pesos ya editados a mano no se pisan.

**Commit:** `git commit -m "Sostener los cargos de compra en el estado del modal"`

---

### Task 15: Sección "Cargos y prorrateo"

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx`

Sección plegable, cerrada por defecto, sólo visible con `tipoFactura === 'FC'`. Con 4,1 ítems promedio por compra, la compra chica no tiene que verla.

Por cargo: concepto, monto (etiquetado **"sin IVA"**), tratamiento fiscal (reusar el selector de condición de la mig 177), dos casillas separadas —*viene en la factura* / *entra al costo*— y la base de reparto. La casilla *afecta la base de impuestos internos* sólo aparece si el tratamiento es `gravado`.

Al lado de esa última casilla, un texto de ayuda corto: *"Un descuento de precio baja la base; una bonificación comercial no."* Es el flag que nadie va a entender sin la explicación.

**Commit:** `git commit -m "Cargar flete, pallets y bonificaciones en el modal de compra"`

---

### Task 16: Grilla de pesos

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx`

Al expandir un cargo, una grilla con una fila por línea de producto: nombre, peso editable, y el monto que le toca (calculado con `prorratearCargo`). Pie con la suma —que siempre debe dar el monto del cargo— y un aviso si todos los pesos son 0.

En mobile, lista apilada en vez de tabla (mirá cómo `ItemRow` resuelve el doble layout, `ModalCompra.tsx:1365`).

**`prorratearCargo` lanza ante un peso no finito o negativo** (contrato de Task 2, a propósito: convertir basura en 0 la vuelve indistinguible de una exclusión deliberada). Consecuencias para esta grilla:

- El input devuelve strings; **parseá en el borde del formulario**, no dejes que llegue un string al cálculo.
- Un campo a medio tipear (`""`, `"-"`, `"1."`) tiene que resolverse a un peso válido antes de llamar, o mostrar el error de esa fila.
- **La vista previa no puede reventar por un throw.** Envolvela: un peso inválido deja esa fila en error, no la pantalla en blanco.

**Commit:** `git commit -m "Repartir un cargo linea por linea desde el modal"`

---

### Task 17: Vista previa por línea

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx`

Tabla con las cuatro columnas que hoy el gerente lee del Excel: **base IVA · impuesto interno · no gravado · IVA**, más el costo unitario final. Alimentada por `calcularCostosCompra`.

Debajo, el total del costo puesto en depósito. Para la factura testigo tiene que dar **12.797.344,26**.

**Commit:** `git commit -m "Mostrar el costo final de cada producto antes de confirmar"`

---

### Task 18: Cuadre del impuesto interno

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx` (`ControlRow` ~línea 1920, `ResumenSection` ~1951)

Extender "Control contra factura" con un campo de II declarado **por alícuota** (las alícuotas presentes en las líneas, no una lista fija).

Mostrar el factor de ajuste resultante. **Si el desvío supera 0,5%, aviso visible**: *"El impuesto interno declarado difiere un X% del calculado. Revisá si alguna bonificación no debería bajar la base, o si alguna alícuota está mal cargada."* Es un aviso, no un bloqueo: hay facturas con redondeos raros.

**Commit:** `git commit -m "Avisar cuando el impuesto interno declarado no cierra"`

---

### Task 19: Plantillas por proveedor

**Files:**
- Modify: `src/components/modals/ModalCompra.tsx`
- Modify: `src/hooks/queries/useComprasQuery.ts`

Botón **"Traer cargos de la última compra de este proveedor"**: query de los `compra_cargos` de la última compra no cancelada de ese proveedor, y los carga con monto en 0 (los conceptos y los flags se reusan; los montos cambian cada vez). Los pesos se remapean por `producto_id`; las líneas que no matchean quedan en 0.

Sin esto el reparto manual no es sostenible: flete y pallets se repiten en cada factura de Manaos.

**Commit:** `git commit -m "Reusar los cargos de la ultima compra del proveedor"`

---

### Task 20: Enviar los cargos a la RPC

**Files:**
- Modify: `src/hooks/queries/useComprasQuery.ts` (`registrarCompra` ~línea 95, `actualizarCompraItems` ~línea 250)
- Modify: `src/components/modals/ModalCompra.tsx` (submit, ~línea 729)
- Modify: `src/components/modals/ModalEditarCompra.tsx`

Agregar `p_cargos` a las dos mutaciones. **Los pesos viajan por índice del array de items, no por id de producto** — ver Task 9.

`ModalEditarCompra` tiene que cargar los cargos existentes y reenviarlos siempre, o la RPC lo rechaza por el guard de Task 10.

No toques `src/hooks/supabase/useCompras.ts` (código muerto, ver la última nota del preámbulo).

**Commit:** `git commit -m "Mandar los cargos a la base al guardar la compra"`

---

## Fase 4 — Verificación end-to-end

### Task 21: Cargar la factura real en la app

**Step 1:** `npm run build` — confirmá que compila (si falla por variables de entorno, es el worktree, no el código).

**Step 2:** Levantá la app y cargá la factura `A0005-00461415` completa: 21 renglones, 6 cargos, II declarado por alícuota.

**Step 3:** Comprobá contra el Excel:
- Factor de ajuste **1,0000** en ambas alícuotas.
- Costo total sin IVA **12.797.344,26**.
- MANAOS LIMA LIMON 600cc: base IVA 4.764,85 · II 198,54 · no gravado 658,97 · costo 5.622,36.
- Los separadores sólo tocan el bidón.

**Step 4:** Guardá y verificá en la base que `productos.costo_real` y `costo_promedio` subieron lo esperado, y que `auditoria_integridad()` sigue en verde.

**Step 5:** Probá editar la compra y confirmá que los cargos sobreviven.

### Task 22: Avisar del cambio en el margen

El costo real de estos productos sube ~16%, así que **el margen reportado va a bajar ~15 puntos**. Avisale al gerente antes de que lo vea en el dashboard: no es una regresión, es que hasta hoy ese 16% no estaba en ningún lado.

---

## Fuera de alcance (no lo hagas en este plan)

- **Una factura repartida entre sucursales.** Hoy son dos compras; el monto del cargo que se carga es el de esa sucursal. Resolverlo de verdad es un cambio de modelo mayor.
- **Análisis de margen y lista de precios** (hojas `AH..AS` y `LISTA PARA PREVENTISTA` del Excel).
- **Notas de crédito posteriores del proveedor.**
