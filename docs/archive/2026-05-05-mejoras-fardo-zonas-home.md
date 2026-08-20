# Mejoras Usuarios — Fardo en Recibos, Zonas en Clientes, Home → Pedidos

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implementar 3 mejoras pedidas por usuarios: (1) imprimir aclaración "(1 FARDO)" / "(MEDIO FARDO)" en recibos y comandas, (2) gestionar Zonas como entidad con panel admin y filtros en clientes, (3) que la home por defecto sea Pedidos para todos los roles.

**Architecture:**
- **Mejora 1**: 1 columna nueva en `productos` + función pura `formatAclaracionBulto()` reusada en los 4 puntos de impresión PDF (recibo comanda, recibo A4, hoja de ruta, manifiesto). TDD sobre la función pura.
- **Mejora 2**: Migración SQL que backfilla `clientes.zona_id` desde el campo texto `clientes.zona`, agrega RLS en `zonas`, extiende `useZonasQuery.ts` con CRUD admin, espeja `ModalCategorias.tsx` → `ModalZonas.tsx`, agrega filtros en `ClientesContainer`.
- **Mejora 3**: Cambio de 1 línea en `App.tsx`.

**Tech Stack:** React 19, TypeScript, Vite, TanStack Query, Supabase (PostgreSQL/PL-pgSQL, RLS), jsPDF, Vitest, Playwright, Tailwind, lucide-react.

**Reference design:** `C:\Users\jorge\.claude\plans\te-paso-las-siguientes-purring-tiger.md`

---

## Mejora 3 — Home = Pedidos (HACEMOS PRIMERO: 1 línea, baja a cero el riesgo)

### Task 1: Cambiar default route a /pedidos

**Files:**
- Modify: `src/App.tsx:205`
- Modify: `src/components/AppRouter.tsx:107` (si existe y no está deprecado)

**Step 1: Verificar que AppRouter.tsx no está en uso**

Run: `grep -rn "AppRouter" src/ --include="*.tsx" --include="*.ts" | grep -v "AppRouter.tsx"`
Expected: 0 referencias (si no, listar dónde se importa).

**Step 2: Cambio en App.tsx línea 205**

```typescript
// Antes
const defaultRoute = (isAdmin || isPreventista || isEncargado) ? '/dashboard' : '/pedidos'

// Después
const defaultRoute = '/pedidos'
```

**Step 3: Cambio en AppRouter.tsx línea 107 (si está en uso)**

```typescript
// Antes
const defaultRoute = (isAdmin || isPreventista) ? '/dashboard' : '/pedidos'

// Después
const defaultRoute = '/pedidos'
```

**Step 4: Verificación manual**

Run: `npm run dev`
- Login como admin → debe abrir en `/pedidos` (no `/dashboard`)
- Click en "Dashboard" del menú → entra a `/dashboard` sin loop
- F5 estando en `/clientes` → permanece en `/clientes`

**Step 5: Typecheck + lint**

Run: `npm run typecheck && npm run lint`
Expected: 0 errores.

**Step 6: Commit**

```bash
git add src/App.tsx src/components/AppRouter.tsx
git commit -m "feat(home): default route is /pedidos for all roles

Users requested opening directly into the Pedidos panel (operational view)
instead of the Dashboard (analytical view). Removes role-based defaultRoute
branching."
```

---

## Mejora 1 — Aclaración de fardo en recibos

### Task 2: Migración SQL — agregar columna unidades_de_venta_por_fardo

**Files:**
- Create: `migrations/031_producto_unidades_por_fardo.sql`

**Step 1: Crear archivo de migración**

```sql
-- Migration 031: Agregar campo de unidades por fardo en productos
-- Permite imprimir aclaración "(1 FARDO)" / "(MEDIO FARDO)" en recibos cuando
-- la cantidad vendida coincide con un múltiplo (entero o medio) del fardo.
--
-- Ejemplo: SAL FINA con unidades_de_venta_por_fardo=2 →
--   1 unidad vendida → "(MEDIO FARDO)"
--   2 unidades       → "(1 FARDO)"
--   3 unidades       → "(1 FARDO Y MEDIO)"
--   4 unidades       → "(2 FARDOS)"

ALTER TABLE productos
  ADD COLUMN IF NOT EXISTS unidades_de_venta_por_fardo numeric(10,2),
  ADD COLUMN IF NOT EXISTS etiqueta_bulto text DEFAULT 'FARDO';

COMMENT ON COLUMN productos.unidades_de_venta_por_fardo IS
  'Cantidad de unidades de venta que componen 1 fardo. Si NULL, no se imprime aclaración.';
COMMENT ON COLUMN productos.etiqueta_bulto IS
  'Etiqueta del bulto (FARDO, CAJA, PACK, BULTO). Default FARDO.';
```

**Step 2: Aplicar la migración en branch de Supabase**

Use el MCP `mcp__261fd064-3c3d-4985-9770-d22ee93274b2__apply_migration` con el SQL anterior, en proyecto `hmuchlzmuqqxcldbzkgc` (ManaosApp). Si necesitás un branch primero, crearlo con `create_branch`.

**Step 3: Verificar columnas creadas**

Use `mcp__261fd064-3c3d-4985-9770-d22ee93274b2__execute_sql`:
```sql
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name='productos'
  AND column_name IN ('unidades_de_venta_por_fardo','etiqueta_bulto');
```
Expected: 2 filas, una numeric, una text con default 'FARDO'.

**Step 4: Commit**

```bash
git add migrations/031_producto_unidades_por_fardo.sql
git commit -m "feat(productos): add unidades_de_venta_por_fardo y etiqueta_bulto

Permite imprimir aclaración (1 FARDO) / (MEDIO FARDO) en recibos cuando la
cantidad vendida coincide con un múltiplo del fardo configurado."
```

---

### Task 3: Función pura formatAclaracionBulto + tests

**Files:**
- Create: `src/lib/pdf/utils/formatBulto.ts`
- Create: `src/lib/pdf/utils/formatBulto.test.ts`

**Step 1: Escribir el test que falla**

```typescript
// src/lib/pdf/utils/formatBulto.test.ts
import { describe, it, expect } from 'vitest';
import { formatAclaracionBulto } from './formatBulto';

describe('formatAclaracionBulto', () => {
  it('returns null when unidadesPorFardo is missing', () => {
    expect(formatAclaracionBulto(2, undefined, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(2, null, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(2, 0, 'FARDO')).toBeNull();
  });

  it('returns null when cantidad is 0 or invalid', () => {
    expect(formatAclaracionBulto(0, 2, 'FARDO')).toBeNull();
    expect(formatAclaracionBulto(NaN, 2, 'FARDO')).toBeNull();
  });

  it('returns "(MEDIO FARDO)" when cantidad/upf === 0.5', () => {
    expect(formatAclaracionBulto(1, 2, 'FARDO')).toBe('(MEDIO FARDO)');
    expect(formatAclaracionBulto(2, 4, 'FARDO')).toBe('(MEDIO FARDO)');
  });

  it('returns "(1 FARDO)" when cantidad/upf === 1', () => {
    expect(formatAclaracionBulto(2, 2, 'FARDO')).toBe('(1 FARDO)');
    expect(formatAclaracionBulto(5, 5, 'FARDO')).toBe('(1 FARDO)');
  });

  it('returns "(1 FARDO Y MEDIO)" when cantidad/upf === 1.5', () => {
    expect(formatAclaracionBulto(3, 2, 'FARDO')).toBe('(1 FARDO Y MEDIO)');
  });

  it('returns "(N FARDOS)" plural for integer multiples >= 2', () => {
    expect(formatAclaracionBulto(4, 2, 'FARDO')).toBe('(2 FARDOS)');
    expect(formatAclaracionBulto(6, 2, 'FARDO')).toBe('(3 FARDOS)');
    expect(formatAclaracionBulto(20, 2, 'FARDO')).toBe('(10 FARDOS)');
  });

  it('returns null for ambiguous fractions (not 0.5 / integer / 1.5)', () => {
    expect(formatAclaracionBulto(1, 3, 'FARDO')).toBeNull();   // 0.33
    expect(formatAclaracionBulto(2, 3, 'FARDO')).toBeNull();   // 0.66
    expect(formatAclaracionBulto(5, 2, 'FARDO')).toBe('(2 FARDOS Y MEDIO)'); // 2.5 → soportar
  });

  it('uses custom etiqueta when provided', () => {
    expect(formatAclaracionBulto(2, 2, 'CAJA')).toBe('(1 CAJA)');
    expect(formatAclaracionBulto(4, 2, 'CAJA')).toBe('(2 CAJAS)');
    expect(formatAclaracionBulto(1, 2, 'CAJA')).toBe('(MEDIA CAJA)');
  });

  it('falls back to FARDO when etiqueta is empty/null', () => {
    expect(formatAclaracionBulto(2, 2, undefined)).toBe('(1 FARDO)');
    expect(formatAclaracionBulto(2, 2, '')).toBe('(1 FARDO)');
  });
});
```

**Step 2: Run test — debe FAIL (módulo no existe)**

Run: `npx vitest run src/lib/pdf/utils/formatBulto.test.ts`
Expected: FAIL — "Cannot find module './formatBulto'".

**Step 3: Implementar formatAclaracionBulto**

```typescript
// src/lib/pdf/utils/formatBulto.ts

/**
 * Devuelve una aclaración entre paréntesis indicando cuántos fardos representa
 * la cantidad vendida, basado en `unidadesPorFardo` configurado en el producto.
 *
 * Reglas:
 * - 0.5 fardo → "(MEDIO FARDO)" / "(MEDIA CAJA)" (femenino para CAJA)
 * - N entero → "(N FARDO)" o "(N FARDOS)" (plural si N>=2)
 * - N.5 con N>=1 → "(N FARDO Y MEDIO)" o "(N FARDOS Y MEDIO)"
 * - Fracciones distintas (1/3, 2/3, etc.) → null
 * - cantidad o unidadesPorFardo inválidos/0 → null
 *
 * @param cantidad Cantidad vendida (item.cantidad)
 * @param unidadesPorFardo Producto.unidades_de_venta_por_fardo
 * @param etiqueta Producto.etiqueta_bulto (default 'FARDO')
 */
export function formatAclaracionBulto(
  cantidad: number,
  unidadesPorFardo: number | null | undefined,
  etiqueta: string | null | undefined,
): string | null {
  if (!cantidad || !Number.isFinite(cantidad) || cantidad <= 0) return null;
  if (!unidadesPorFardo || !Number.isFinite(unidadesPorFardo) || unidadesPorFardo <= 0) return null;

  const ratio = cantidad / unidadesPorFardo;
  const label = (etiqueta && etiqueta.trim()) ? etiqueta.trim().toUpperCase() : 'FARDO';

  // Plural y "medio/media" según género de la palabra (CAJA/MEDIA, FARDO/MEDIO).
  // Heurística: termina en 'A' → femenino.
  const isFem = label.endsWith('A');
  const medio = isFem ? 'MEDIA' : 'MEDIO';
  const labelPlural = isFem ? `${label}S` : `${label}S`; // FARDOS / CAJAS

  // Caso medio fardo
  if (ratio === 0.5) return `(${medio} ${label})`;

  // Caso entero
  if (Number.isInteger(ratio)) {
    return ratio === 1 ? `(1 ${label})` : `(${ratio} ${labelPlural})`;
  }

  // Caso N.5 con N>=1
  const entero = Math.floor(ratio);
  const fraccion = ratio - entero;
  if (fraccion === 0.5 && entero >= 1) {
    const palabra = entero === 1 ? label : labelPlural;
    return `(${entero} ${palabra} Y MEDIO)`;
  }

  return null;
}
```

**Step 4: Run test — debe PASS**

Run: `npx vitest run src/lib/pdf/utils/formatBulto.test.ts`
Expected: 8 tests passed.

**Step 5: Commit**

```bash
git add src/lib/pdf/utils/formatBulto.ts src/lib/pdf/utils/formatBulto.test.ts
git commit -m "feat(pdf): add formatAclaracionBulto pure helper + tests

Calcula la aclaración (1 FARDO / MEDIO FARDO / 1 FARDO Y MEDIO / N FARDOS)
desde cantidad y unidadesPorFardo. Soporta etiquetas custom (CAJA/MEDIA CAJA).
Devuelve null para fracciones ambiguas (1/3, 2/3, etc.)."
```

---

### Task 4: Tipos TypeScript de Producto

**Files:**
- Modify: `src/types/index.ts:51-74` (Producto, ProductoInput)

**Step 1: Agregar campos opcionales**

```typescript
// src/types/index.ts (Producto)
export interface Producto extends BaseEntity {
  codigo?: string;
  nombre: string;
  descripcion?: string;
  precio_unitario: number;
  precio_mayorista?: number;
  stock: number;
  stock_minimo?: number;
  categoria_id?: string;
  activo: boolean;
  unidad?: string;
  // NUEVOS
  unidades_de_venta_por_fardo?: number;
  etiqueta_bulto?: string;
}

export interface ProductoInput {
  codigo?: string;
  nombre: string;
  descripcion?: string;
  precio_unitario: number;
  precio_mayorista?: number;
  stock?: number;
  stock_minimo?: number;
  categoria_id?: string;
  unidad?: string;
  // NUEVOS
  unidades_de_venta_por_fardo?: number;
  etiqueta_bulto?: string;
}
```

**Step 2: Verificar el tipo `ProductoDB` de hooks queries**

Run: `grep -n "ProductoDB" src/hooks/queries/ -r`
Si existe un tipo `ProductoDB` espejado a la tabla, agregar también allí los 2 campos opcionales (mismos nombres exactos que en SQL).

**Step 3: Typecheck**

Run: `npm run typecheck`
Expected: 0 errores.

**Step 4: Commit**

```bash
git add src/types/index.ts src/hooks/queries/
git commit -m "types(producto): add unidades_de_venta_por_fardo y etiqueta_bulto"
```

---

### Task 5: Form de Producto (ModalProducto.tsx)

**Files:**
- Modify: `src/components/modals/ModalProducto.tsx`

**Step 1: Leer el form actual y ubicar el campo `unidad`**

Run: `grep -n "unidad" src/components/modals/ModalProducto.tsx`
Anotar las líneas para ubicar dónde agregar los nuevos inputs (justo debajo).

**Step 2: Agregar inputs al form**

Después del input de `unidad`, agregar:

```tsx
<div className="grid grid-cols-2 gap-3">
  <div>
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      Unidades por bulto/fardo
    </label>
    <input
      type="number"
      step="0.5"
      min="0"
      value={formData.unidades_de_venta_por_fardo ?? ''}
      onChange={(e) => setFormData({
        ...formData,
        unidades_de_venta_por_fardo: e.target.value === '' ? undefined : Number(e.target.value),
      })}
      className="mt-1 block w-full rounded-md border-gray-300 ..."
      placeholder="ej. 2"
    />
    <p className="text-xs text-gray-500 mt-1">
      Cuántas unidades de venta hacen 1 fardo. Si 1 unidad = medio fardo, poné 2.
    </p>
  </div>
  <div>
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      Etiqueta del bulto
    </label>
    <input
      type="text"
      value={formData.etiqueta_bulto ?? 'FARDO'}
      onChange={(e) => setFormData({ ...formData, etiqueta_bulto: e.target.value.toUpperCase() })}
      className="mt-1 block w-full rounded-md border-gray-300 ..."
      placeholder="FARDO"
      maxLength={20}
    />
    <p className="text-xs text-gray-500 mt-1">
      FARDO, CAJA, PACK, BULTO...
    </p>
  </div>
</div>
```

(Usar las mismas clases Tailwind que los otros inputs del form para consistencia visual — leer el archivo y copiar el patrón.)

**Step 3: Asegurar que se envían en el insert/update**

Buscar el callback `onSubmit` o mutación `useCrearProductoMutation`/`useActualizarProductoMutation`. Verificar que el payload incluya `unidades_de_venta_por_fardo` y `etiqueta_bulto`. Si la mutación filtra campos por allowlist, agregarlos.

**Step 4: Verificación manual**

Run: `npm run dev`
- Editar un producto, setear unidades_por_fardo=2 y guardar.
- Verificar en Supabase que se guardó:
  ```sql
  SELECT id, nombre, unidades_de_venta_por_fardo, etiqueta_bulto
  FROM productos WHERE id = <id>;
  ```

**Step 5: Typecheck + lint + commit**

```bash
npm run typecheck && npm run lint
git add src/components/modals/ModalProducto.tsx src/hooks/queries/
git commit -m "feat(productos): UI form para unidades_por_fardo y etiqueta_bulto"
```

---

### Task 6: Integrar en recibo comanda (reciboPedido.js:386)

**Files:**
- Modify: `src/lib/pdf/reciboPedido.js:382-393`

**Step 1: Importar la función pura**

Al tope del archivo:
```javascript
import { formatAclaracionBulto } from './utils/formatBulto';
```

**Step 2: Modificar el loop de items en `dibujarComanda`**

```javascript
items.forEach(item => {
  const productoNombre = item.producto?.nombre || 'Producto'
  const subtotal = item.subtotal || item.precio_unitario * item.cantidad

  const aclaracion = formatAclaracionBulto(
    item.cantidad,
    item.producto?.unidades_de_venta_por_fardo,
    item.producto?.etiqueta_bulto,
  );
  const lineaProducto = aclaracion
    ? `${item.cantidad}x ${productoNombre} ${aclaracion}`
    : `${item.cantidad}x ${productoNombre}`;

  const nombreLines = doc.splitTextToSize(lineaProducto, contentWidth - 26)
  // ... resto igual
})
```

**Step 3: Repetir cambio en `generarReciboA4` (mismo archivo)**

Run: `grep -n "generarReciboA4\|item.cantidad.*productoNombre\|item\.cantidad}x" src/lib/pdf/reciboPedido.js`
Encontrar el loop equivalente en el A4 y aplicar la misma transformación.

**Step 4: Verificación manual**

Run: `npm run dev`
- Crear pedido con 1 ud del producto editado en Task 5 → imprimir comanda → debe mostrar `1x ... (MEDIO FARDO)`.
- Editar a 2 uds → reimprimir → `2x ... (1 FARDO)`.
- Editar a 4 uds → `4x ... (2 FARDOS)`.

**Step 5: Commit**

```bash
git add src/lib/pdf/reciboPedido.js
git commit -m "feat(recibo): imprimir aclaración (N FARDO) en comanda y A4"
```

---

### Task 7: Integrar en hoja de ruta y manifiesto

**Files:**
- Modify: `src/lib/pdf/hojaRutaOptimizada.js:158` (buildCardOps)
- Modify: `src/lib/pdf/hojaRutaOptimizada.js:289+` (buildManifiestoOps)

**Step 1: Importar la función**

```javascript
import { formatAclaracionBulto } from './utils/formatBulto';
```

**Step 2: Modificar `buildCardOps` línea ~158**

Buscar la línea `doc.splitTextToSize(\`${item.cantidad}x ${nombre}\`, ...)` y cambiar:

```javascript
const aclaracion = formatAclaracionBulto(
  item.cantidad,
  item.producto?.unidades_de_venta_por_fardo,
  item.producto?.etiqueta_bulto,
);
const linea = aclaracion ? `${item.cantidad}x ${nombre} ${aclaracion}` : `${item.cantidad}x ${nombre}`;
doc.splitTextToSize(linea, ...);
```

**Step 3: Modificar `buildManifiestoOps` línea ~289**

El manifiesto consolida cantidades por producto. Aplicar la aclaración basada en la cantidad TOTAL consolidada (no por pedido individual). Buscar dónde se renderiza la línea final del manifiesto y agregar la aclaración usando el `producto` de cada totales[key].

**Step 4: Verificación manual**

- Crear 2 pedidos con el mismo producto (1 ud y 2 uds) → imprimir hoja de ruta → cada tarjeta debe mostrar la aclaración correcta + el manifiesto debe mostrar `3 uds → (1 FARDO Y MEDIO)`.

**Step 5: Commit**

```bash
git add src/lib/pdf/hojaRutaOptimizada.js
git commit -m "feat(hoja-ruta): imprimir aclaración (N FARDO) en tarjetas y manifiesto"
```

---

### Task 8: Asegurar que `item.producto` se carga en queries de pedido

**Files:**
- Posiblemente: `src/hooks/queries/usePedidosQuery.ts` o similar

**Step 1: Verificar que la query de items incluye los nuevos campos**

Run: `grep -rn "from.*pedido_items\|select.*producto" src/hooks/queries/ | head -20`
Las queries que hacen `.select('*, producto:producto_id (*)')` ya traerán los nuevos campos. Las que usan select explícito por columnas (ej. `.select('id,nombre,precio')`) deben actualizarse para incluir `unidades_de_venta_por_fardo, etiqueta_bulto`.

**Step 2: Verificar en runtime**

En DevTools console, durante un pedido cargado:
```js
console.log(pedido.items[0].producto.unidades_de_venta_por_fardo)
```
Debe ser un número, no `undefined`.

**Step 3: Si falta, ajustar el select y commit**

```bash
git add src/hooks/queries/
git commit -m "fix(pedidos): incluir campos de fardo en select de productos"
```

---

## Mejora 2 — Zonas en clientes (entidad + filtros)

### Task 9: Migración SQL — backfill zona_id y RLS de zonas

**Files:**
- Create: `migrations/032_migrar_clientes_zona_a_zona_id.sql`

**Step 1: Crear migración**

```sql
-- Migration 032: Migrar clientes.zona (texto) → clientes.zona_id (FK a zonas)
-- También asegura que tabla `zonas` tenga RLS configurado (admin para mutaciones,
-- select para usuarios de la sucursal).
--
-- Mantiene clientes.zona como columna deprecada un release para rollback seguro.

-- 0. RLS de zonas si no existe (parcial — mt_zonas_*)
ALTER TABLE zonas ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS mt_zonas_select ON zonas;
CREATE POLICY mt_zonas_select ON zonas
  FOR SELECT TO authenticated
  USING (sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_zonas_insert ON zonas;
CREATE POLICY mt_zonas_insert ON zonas
  FOR INSERT TO authenticated
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_zonas_update ON zonas;
CREATE POLICY mt_zonas_update ON zonas
  FOR UPDATE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id())
  WITH CHECK (es_admin() AND sucursal_id = current_sucursal_id());

DROP POLICY IF EXISTS mt_zonas_delete ON zonas;
CREATE POLICY mt_zonas_delete ON zonas
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

-- 1. Insertar zonas únicas que existen como texto en clientes pero no en zonas
INSERT INTO zonas (nombre, sucursal_id, activo)
SELECT DISTINCT trim(c.zona), c.sucursal_id, true
FROM clientes c
WHERE c.zona IS NOT NULL
  AND trim(c.zona) <> ''
  AND NOT EXISTS (
    SELECT 1 FROM zonas z
    WHERE lower(trim(z.nombre)) = lower(trim(c.zona))
      AND z.sucursal_id = c.sucursal_id
  );

-- 2. Backfill clientes.zona_id desde clientes.zona
UPDATE clientes c
SET zona_id = z.id
FROM zonas z
WHERE c.zona_id IS NULL
  AND c.zona IS NOT NULL
  AND lower(trim(z.nombre)) = lower(trim(c.zona))
  AND z.sucursal_id = c.sucursal_id;

-- 3. Recrear vista del bot que referencia c.zona como texto
DROP VIEW IF EXISTS bot_clientes_huerfanos_visibles;
CREATE VIEW bot_clientes_huerfanos_visibles AS
SELECT c.id, c.nombre, c.telefono, c.saldo_cuenta, c.direccion,
       z.nombre AS zona, c.sucursal_id
FROM clientes c
LEFT JOIN zonas z ON z.id = c.zona_id
WHERE NOT EXISTS (
  SELECT 1 FROM cliente_preventistas cp WHERE cp.cliente_id = c.id
);

GRANT SELECT ON bot_clientes_huerfanos_visibles TO authenticated, anon, service_role;

-- 4. Comentar deprecación
COMMENT ON COLUMN clientes.zona IS
  'DEPRECADO desde 2026-05-05 — usar zona_id (FK a zonas). Se mantiene para rollback.';
```

**Step 2: Verificar la firma actual de la vista bot_clientes_huerfanos_visibles**

Run con MCP `execute_sql`:
```sql
SELECT pg_get_viewdef('bot_clientes_huerfanos_visibles', true);
```
Si la vista tiene más columnas o WHERE distinto, ajustar el CREATE VIEW arriba.

**Step 3: Aplicar migración (en branch de Supabase)**

Use `mcp__261fd064-3c3d-4985-9770-d22ee93274b2__create_branch` y luego `apply_migration`.

**Step 4: Verificar resultados**

```sql
-- ¿Cuántas zonas se crearon?
SELECT count(*) FROM zonas;
-- ¿Cuántos clientes quedaron con zona_id?
SELECT count(*) FROM clientes WHERE zona_id IS NOT NULL;
SELECT count(*) FROM clientes WHERE zona IS NOT NULL AND zona_id IS NULL;
-- (la 2ª query debería ser 0 si todas las zonas texto matchean — si no, listar para revisión manual)
```

**Step 5: Verificar RLS**

```sql
SELECT polname, polcmd FROM pg_policy
WHERE polrelid = 'zonas'::regclass;
```
Expected: 4 policies (select/insert/update/delete) con prefijo mt_zonas_.

**Step 6: Commit migración**

```bash
git add migrations/032_migrar_clientes_zona_a_zona_id.sql
git commit -m "feat(zonas): RLS + backfill clientes.zona_id desde texto

- Habilita RLS en tabla zonas con políticas mt_zonas_* (admin para mutaciones).
- Backfill de zonas existentes en clientes.zona (texto) hacia tabla zonas.
- Update de clientes.zona_id apuntando a la zona correspondiente.
- Recrea bot_clientes_huerfanos_visibles para joinear con zonas.
- Marca clientes.zona como deprecado (se mantiene un release para rollback)."
```

---

### Task 10: Extender useZonasQuery.ts con CRUD admin

**Files:**
- Modify: `src/hooks/queries/useZonasQuery.ts`
- Create: `src/hooks/queries/useZonasQuery.test.ts` (opcional pero recomendado)

**Step 1: Agregar funciones de mutación**

```typescript
// src/hooks/queries/useZonasQuery.ts — agregar al final, antes del export

async function renombrarZona(id: string, nombre: string): Promise<void> {
  const trimmed = nombre.trim();
  if (!trimmed) throw new Error('El nombre de la zona es requerido');
  const { error } = await supabase.from('zonas').update({ nombre: trimmed }).eq('id', id);
  if (error) {
    if (error.code === '23505') throw new Error(`La zona "${trimmed}" ya existe`);
    throw error;
  }
}

async function eliminarZona(id: string): Promise<void> {
  // Validar que no haya clientes asignados
  const { count, error: countError } = await supabase
    .from('clientes')
    .select('id', { count: 'exact', head: true })
    .eq('zona_id', id);
  if (countError) throw countError;
  if ((count ?? 0) > 0) {
    throw new Error(`No se puede eliminar: hay ${count} cliente(s) asignados a esta zona. Reasignalos primero.`);
  }
  const { error } = await supabase.from('zonas').delete().eq('id', id);
  if (error) throw error;
}

async function toggleZonaActiva(id: string, activo: boolean): Promise<void> {
  const { error } = await supabase.from('zonas').update({ activo }).eq('id', id);
  if (error) throw error;
}

export function useRenombrarZonaMutation() {
  const queryClient = useQueryClient();
  const { currentSucursalId } = useSucursal();
  return useMutation({
    mutationFn: ({ id, nombre }: { id: string; nombre: string }) => renombrarZona(id, nombre),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) });
    },
  });
}

export function useEliminarZonaMutation() {
  const queryClient = useQueryClient();
  const { currentSucursalId } = useSucursal();
  return useMutation({
    mutationFn: eliminarZona,
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) });
    },
  });
}

export function useToggleZonaActivaMutation() {
  const queryClient = useQueryClient();
  const { currentSucursalId } = useSucursal();
  return useMutation({
    mutationFn: ({ id, activo }: { id: string; activo: boolean }) => toggleZonaActiva(id, activo),
    onSuccess: () => {
      queryClient.invalidateQueries({ queryKey: zonasKeys.all(currentSucursalId) });
    },
  });
}
```

**Step 2: Cambiar `fetchZonas` para que liste también inactivas (usadas por panel admin)**

```typescript
async function fetchZonas(includeInactive = false): Promise<ZonaDB[]> {
  let q = supabase.from('zonas').select('*').order('nombre');
  if (!includeInactive) q = q.eq('activo', true);
  const { data, error } = await q;
  if (error) throw error;
  return (data as ZonaDB[]) || [];
}

export function useZonasEstandarizadasQuery(opts?: { includeInactive?: boolean }) {
  const { currentSucursalId } = useSucursal();
  return useQuery({
    queryKey: [...zonasKeys.lists(currentSucursalId), opts?.includeInactive ?? false],
    queryFn: () => fetchZonas(opts?.includeInactive),
    staleTime: 10 * 60 * 1000,
  });
}
```

**Step 3: Typecheck**

Run: `npm run typecheck`

**Step 4: Commit**

```bash
git add src/hooks/queries/useZonasQuery.ts
git commit -m "feat(zonas): hooks renombrar/eliminar/toggle + includeInactive"
```

---

### Task 11: ModalZonas (espejo de ModalCategorias)

**Files:**
- Create: `src/components/modals/ModalZonas.tsx`

**Step 1: Leer ModalCategorias completo**

Run: `cat src/components/modals/ModalCategorias.tsx`
Identificar el patrón completo (estado local, render, mutaciones).

**Step 2: Crear ModalZonas.tsx adaptado**

Copia simplificada (sin "derivadas", porque al haber FK no hay strings huérfanos):

```typescript
// src/components/modals/ModalZonas.tsx
import { memo, useState } from 'react';
import { Loader2, Plus, Pencil, Trash2, Check, X, MapPin, AlertCircle, ToggleLeft, ToggleRight } from 'lucide-react';
import ModalBase from './ModalBase';
import {
  useZonasEstandarizadasQuery,
  useCrearZonaMutation,
  useRenombrarZonaMutation,
  useEliminarZonaMutation,
  useToggleZonaActivaMutation,
} from '../../hooks/queries/useZonasQuery';
import type { ZonaDB } from '../../hooks/queries/useZonasQuery';

export interface ModalZonasProps {
  onClose: () => void;
}

const ModalZonas = memo(function ModalZonas({ onClose }: ModalZonasProps) {
  const { data: zonas = [], isLoading } = useZonasEstandarizadasQuery({ includeInactive: true });
  const crearMut = useCrearZonaMutation();
  const renameMut = useRenombrarZonaMutation();
  const deleteMut = useEliminarZonaMutation();
  const toggleMut = useToggleZonaActivaMutation();

  const [nuevoNombre, setNuevoNombre] = useState('');
  const [error, setError] = useState('');
  const [editandoId, setEditandoId] = useState<string | null>(null);
  const [editNombre, setEditNombre] = useState('');
  const [confirmDelete, setConfirmDelete] = useState<ZonaDB | null>(null);

  const handleCrear = async () => {
    const nombre = nuevoNombre.trim();
    if (!nombre) { setError('El nombre es requerido'); return; }
    try {
      await crearMut.mutateAsync(nombre);
      setNuevoNombre('');
      setError('');
    } catch (e: any) {
      setError(e.message || 'Error creando zona');
    }
  };

  // ... (espejar el resto de handlers de ModalCategorias: handleRename, handleDelete, handleToggleActiva)
  // ... (renderizar ModalBase con la misma estructura visual)

  return (
    <ModalBase isOpen onClose={onClose} title="Gestionar Zonas">
      {/* INPUT crear */}
      <div className="flex gap-2 mb-4">
        <input
          type="text"
          value={nuevoNombre}
          onChange={(e) => setNuevoNombre(e.target.value)}
          onKeyDown={(e) => e.key === 'Enter' && handleCrear()}
          placeholder="Nueva zona..."
          className="flex-1 rounded-md border-gray-300 ..."
        />
        <button onClick={handleCrear} disabled={crearMut.isPending} className="...">
          <Plus className="w-4 h-4" /> Crear
        </button>
      </div>
      {error && <p className="text-red-600 text-sm mb-2"><AlertCircle className="inline w-4 h-4" /> {error}</p>}

      {/* LISTA */}
      {isLoading ? <Loader2 className="animate-spin" /> : (
        <ul className="divide-y">
          {zonas.map(z => (
            <li key={z.id} className="py-2 flex items-center gap-2">
              {/* ... edit/toggle/delete buttons como en ModalCategorias */}
            </li>
          ))}
        </ul>
      )}
    </ModalBase>
  );
});

export default ModalZonas;
```

(Completar con fidelidad al patrón de ModalCategorias.)

**Step 3: Typecheck + lint**

```bash
npm run typecheck && npm run lint
```

**Step 4: Commit**

```bash
git add src/components/modals/ModalZonas.tsx
git commit -m "feat(zonas): ModalZonas para gestión admin (espejo de ModalCategorias)"
```

---

### Task 12: Tipo Cliente + ModalCliente con select de zona

**Files:**
- Modify: `src/types/index.ts:23-45` (Cliente, ClienteInput)
- Modify: `src/components/modals/ModalCliente.tsx`

**Step 1: Agregar zona_id a tipos**

```typescript
export interface Cliente extends BaseEntity {
  nombre: string;
  direccion?: string;
  telefono?: string;
  email?: string;
  /** @deprecated usar zona_id */
  zona?: string;
  zona_id?: string;
  tipo?: 'minorista' | 'mayorista' | 'distribuidor';
  activo: boolean;
  saldo_pendiente?: number;
  notas?: string;
  latitud?: number;
  longitud?: number;
}

export interface ClienteInput {
  nombre: string;
  direccion?: string;
  telefono?: string;
  email?: string;
  /** @deprecated usar zona_id */
  zona?: string;
  zona_id?: string;
  tipo?: 'minorista' | 'mayorista' | 'distribuidor';
  notas?: string;
}
```

**Step 2: Reemplazar input texto `zona` por select**

En `ModalCliente.tsx`, ubicar el campo `zona` (texto) y reemplazar:

```tsx
import { useZonasEstandarizadasQuery } from '../../hooks/queries/useZonasQuery';
// ...
const { data: zonas = [] } = useZonasEstandarizadasQuery();
// ...
<div>
  <label className="block text-sm font-medium">Zona</label>
  <select
    value={formData.zona_id ?? ''}
    onChange={(e) => setFormData({ ...formData, zona_id: e.target.value || undefined })}
    className="mt-1 block w-full rounded-md border-gray-300 ..."
  >
    <option value="">(Sin zona)</option>
    {zonas.map(z => (
      <option key={z.id} value={z.id}>{z.nombre}</option>
    ))}
  </select>
</div>
```

**Step 3: Asegurar que el payload del crear/actualizar manda zona_id en vez de zona**

Buscar la mutación correspondiente y verificar que envía `zona_id` (no `zona`). Si la mutación tipa estricto, ya estará alineado.

**Step 4: Verificación manual**

- Editar un cliente, cambiar zona en select, guardar.
- Verificar en Supabase: `SELECT zona, zona_id FROM clientes WHERE id=<id>;` — `zona_id` debe ser un bigint, `zona` queda como estaba (deprecado).

**Step 5: Typecheck + lint + commit**

```bash
npm run typecheck && npm run lint
git add src/types/index.ts src/components/modals/ModalCliente.tsx
git commit -m "feat(clientes): select de zona usando zona_id (FK)"
```

---

### Task 13: Botón "Gestionar Zonas" + filtros en ClientesContainer

**Files:**
- Modify: `src/components/containers/ClientesContainer.tsx`
- Posiblemente: `src/components/vistas/VistaClientes.tsx` (donde se renderizan filtros)

**Step 1: Leer el container y la vista actuales**

Run: `cat src/components/containers/ClientesContainer.tsx | head -100`
Ubicar dónde se renderizan los botones de acción (similar a "Categorías" en ProductosContainer) y los filtros.

**Step 2: Importar ModalZonas y agregar estado**

```typescript
import { lazy, Suspense, useState } from 'react';
const ModalZonas = lazy(() => import('../modals/ModalZonas'));
import { useAuthData } from '../../contexts/AuthDataContext';
// ...
const { isAdmin } = useAuthData();
const [showZonasModal, setShowZonasModal] = useState(false);
```

**Step 3: Botón visible solo a admin**

Donde estén los botones de toolbar:
```tsx
{isAdmin && (
  <button
    onClick={() => setShowZonasModal(true)}
    className="..."
  >
    <MapPin className="w-4 h-4" /> Gestionar Zonas
  </button>
)}
```

Y al final del JSX:
```tsx
{showZonasModal && (
  <Suspense fallback={null}>
    <ModalZonas onClose={() => setShowZonasModal(false)} />
  </Suspense>
)}
```

**Step 4: Filtros — Zona y Estado de cuenta**

Identificar el lugar donde se aplican filtros existentes (search, tipo, etc.) y agregar:

```typescript
const [filtroZonaId, setFiltroZonaId] = useState<string>(''); // '' = todas
const [filtroSaldo, setFiltroSaldo] = useState<'todos' | 'deben' | 'no_deben'>('todos');

const clientesFiltrados = useMemo(() => {
  return clientes.filter(c => {
    if (filtroZonaId && String(c.zona_id) !== filtroZonaId) return false;
    const saldo = c.saldo_pendiente ?? 0;
    if (filtroSaldo === 'deben' && saldo <= 0) return false;
    if (filtroSaldo === 'no_deben' && saldo > 0) return false;
    return true;
  });
}, [clientes, filtroZonaId, filtroSaldo]);
```

UI de filtros:
```tsx
<select value={filtroZonaId} onChange={(e) => setFiltroZonaId(e.target.value)}>
  <option value="">Todas las zonas</option>
  {zonas.map(z => <option key={z.id} value={z.id}>{z.nombre}</option>)}
</select>

<select value={filtroSaldo} onChange={(e) => setFiltroSaldo(e.target.value as any)}>
  <option value="todos">Todos</option>
  <option value="deben">Deben</option>
  <option value="no_deben">No deben</option>
</select>
```

**Step 5: Verificación manual**

- Como admin: ver el botón "Gestionar Zonas". Como preventista: NO debe verse.
- Filtrar por zona "X" → solo aparecen clientes con `zona_id = X`.
- Filtrar "Deben" → solo `saldo_pendiente > 0`.
- Combinar ambos filtros → AND lógico.

**Step 6: Typecheck + lint + commit**

```bash
npm run typecheck && npm run lint
git add src/components/containers/ClientesContainer.tsx src/components/vistas/VistaClientes.tsx
git commit -m "feat(clientes): filtros por zona y estado de cuenta + botón admin"
```

---

## Verificación Final

### Task 14: Smoke test E2E + linting global

**Step 1: Typecheck completo**

Run: `npm run typecheck`
Expected: 0 errores.

**Step 2: Lint**

Run: `npm run lint`
Expected: 0 errores.

**Step 3: Test unitarios**

Run: `npm run test:run`
Expected: todos los tests verdes (incluyendo `formatBulto.test.ts`).

**Step 4: Build**

Run: `npm run build`
Expected: build exitoso.

**Step 5: Smoke manual end-to-end**

Seguir la sección "Verificación end-to-end" del design doc en `C:\Users\jorge\.claude\plans\te-paso-las-siguientes-purring-tiger.md`:
- Mejora 1: 7 escenarios (1 ud, 2 uds, 3 uds, 4 uds, sin campo, hoja de ruta, manifiesto).
- Mejora 2: 7 escenarios (migración aplicada, modal admin solo visible para admin, select en form, filtros, RLS, bot view).
- Mejora 3: 4 escenarios (login por rol, dashboard accesible desde menú, F5 sin redirect).

**Step 6: Smoke E2E playwright (opcional pero recomendado)**

Run: `npm run test:e2e -- --grep "clientes|pedidos"` (si hay tests existentes que cubran estos flows).

**Step 7: PR**

Crear PR con cuerpo enlazando este plan, el design doc, y la foto de referencia del recibo #1450.

---

## Notas de Implementación

- **Orden recomendado de ejecución**: Mejora 3 (1 línea) → Mejora 1 (function pura → migración → form → PDFs) → Mejora 2 (migración → hooks → modal → form cliente → filtros). Permite shipear cambios incrementalmente.
- **Si una migración SQL falla**: usar `rebase_branch` o `reset_branch` del MCP supabase para volver atrás antes de reintentar.
- **El campo `clientes.zona` (texto) NO se borra en este release** — se elimina en migración futura una vez confirmado que nadie lo lee desde el frontend.
- **La RLS de zonas no estaba en el baseline** — la creamos en Task 9. Verificar que no rompe queries existentes (la `useZonasEstandarizadasQuery` ya existe y se usa para preventistas).
- **Para clientes con `zona` (texto) que no matchea ninguna zona normalizada**: la migración 032 crea la zona automáticamente con el nombre exacto. Después se puede limpiar/normalizar desde el modal admin.
