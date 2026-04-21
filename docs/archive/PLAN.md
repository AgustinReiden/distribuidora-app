# Plan de Mejoras - Distribuidora App

## Mejora 1: Zonas - Múltiples zonas por preventista + estandarización

### Estado actual
- `perfiles.zona` es un campo VARCHAR(50) simple - solo UNA zona por preventista
- `clientes.zona` es un campo VARCHAR(50) simple
- `proveedores` NO tiene campo zona
- ModalCliente tiene una lista predefinida hardcodeada (`ZONAS_PREDEFINIDAS`) + zonas de clientes DB
- ModalUsuario tiene un input de texto libre con datalist de sugerencias
- No hay tabla `zonas` centralizada

### Cambios propuestos

#### 1.1 - Migración SQL: tabla `zonas` + tabla pivot `preventista_zonas`
**Archivo nuevo:** `migrations/027_zonas_estandarizadas.sql`
- Crear tabla `zonas` (id, nombre VARCHAR(100) UNIQUE, activo BOOLEAN DEFAULT true, created_at)
- Crear tabla `preventista_zonas` (id, perfil_id FK→perfiles, zona_id FK→zonas, UNIQUE(perfil_id, zona_id))
- Agregar columna `zona_id` a `proveedores` (FK→zonas, nullable)
- Agregar columna `zona_id` a `clientes` (FK→zonas, nullable, coexiste con zona texto viejo)
- INSERT INTO zonas las `ZONAS_PREDEFINIDAS` actuales + zonas únicas existentes en clientes
- Migrar datos: para cada cliente con zona texto, buscar/crear el zona_id correspondiente
- Migrar datos: para cada preventista con zona texto, crear registro en preventista_zonas

#### 1.2 - Tipos TypeScript
**Archivo:** `src/types/hooks.ts`
- Agregar `ZonaDB { id: string; nombre: string; activo?: boolean; created_at?: string }`
- Agregar `PreventistaZonaDB { id: string; perfil_id: string; zona_id: string }`
- Actualizar `PerfilDB` para agregar `zonas?: ZonaDB[]` (array en vez de string)
- Actualizar `ProveedorDBExtended` para agregar `zona_id?: string | null`
- Actualizar `ClienteDB` para agregar `zona_id?: string | null`

#### 1.3 - Queries: hook `useZonasQuery`
**Archivo:** `src/hooks/queries/useZonasQuery.ts` (nuevo)
- `fetchZonas()` - todas las zonas activas ordenadas por nombre
- `useZonasQuery()` - hook TanStack Query
- `crearZona(nombre)` - inserta nueva zona con validación de unicidad
- `actualizarZona(id, nombre)` - rename
- `eliminarZona(id)` - soft delete (activo=false) solo si no tiene clientes/proveedores/preventistas asociados

#### 1.4 - Queries: actualizar `useUsuariosQuery`
**Archivo:** `src/hooks/queries/useUsuariosQuery.ts`
- `fetchPreventistas()` debe hacer join con preventista_zonas + zonas para traer el array de zonas
- Agregar `asignarZonasPreventista(perfilId, zonaIds[])` - reemplaza todas las zonas del preventista

#### 1.5 - UI: ModalCliente - filtro por zona + agregar zonas
**Archivo:** `src/components/modals/ModalCliente.tsx`
- Reemplazar `ZONAS_PREDEFINIDAS` hardcodeado por `useZonasQuery()`
- El select de zona ahora usa `zona_id` en vez de texto libre
- "Nueva zona" ahora llama a `crearZona()` que persiste en tabla `zonas` (estandarización)
- Se mantiene la misma UX: dropdown + botón "+ Nueva zona"
- Al guardar cliente, guardar `zona_id` además de `zona` (texto) para compatibilidad

#### 1.6 - UI: ModalUsuario - múltiples zonas con dropdown
**Archivo:** `src/components/modals/ModalUsuario.tsx`
- Cambiar campo `zona: string` a `zonas: string[]` (array de zona_ids)
- Reemplazar input texto+datalist por un multi-select con checkboxes de las zonas disponibles
- Al guardar, llamar `asignarZonasPreventista(perfilId, zonaIds[])`
- Mostrar chips/tags de zonas seleccionadas con botón X para remover

#### 1.7 - UI: ModalProveedor - agregar campo zona
**Archivo:** `src/components/modals/ModalProveedor.tsx`
- Agregar campo `zona_id` al formulario con dropdown de zonas (de `useZonasQuery()`)
- Mismo estilo dropdown que ModalCliente

#### 1.8 - Actualizar handlers
**Archivos:** `useUsuarioHandlers.ts`, `useClienteHandlers.ts`, `useProveedorHandlers.ts`
- Adaptar funciones de guardar para enviar zona_id / zonas según corresponda

---

## Mejora 2: Bonificación en porcentaje + Impuestos internos como porcentaje persistente

### Estado actual - Bonificación
- `CompraItemForm.bonificacion` es un número entero (cantidad fija)
- NO se usa en los cálculos de subtotal/total (se almacena pero se ignora en `useCalculosImpuestos`)
- El input usa `parseInt` y `min="0"` sin decimales
- La DB (`compra_items`) no tiene columna bonificación

### Estado actual - Impuestos internos
- `ProductoDB.impuestos_internos` es un monto fijo por unidad (DECIMAL(12,2))
- En compras se carga por item y es editable manualmente cada vez
- `calcularTotalConIva()` lo suma como monto fijo: `neto + iva + internos`
- En ModalProducto se puede editar el impuesto interno del producto

### Cambios propuestos

#### 2.1 - Bonificación como porcentaje con decimales
**Archivo:** `src/components/modals/ModalCompra.tsx`
- Cambiar `CompraItemForm.bonificacion` de entero a `number` con decimales (porcentaje 0-100)
- Cambiar inputs de bonificación: `step="0.01"`, `max="100"`, placeholder `%`
- Cambiar parser de `parseInt` a `parseFloat`
- Agregar sufijo visual `%` al label: "Bonif. %"

**Archivo:** `src/components/modals/ModalCompra.tsx` - `useCalculosImpuestos`
- Modificar cálculo de subtotal para aplicar bonificación como descuento porcentual:
  ```
  costoConBonif = costoUnitario * (1 - bonificacion/100)
  subtotal = SUM(cantidad * costoConBonif)
  ```
- El IVA se calcula sobre el subtotal ya bonificado
- Impuestos internos se aplican sobre el neto bonificado

**Archivo:** `src/components/modals/ModalImportarCompra.tsx`
- Adaptar parsing de Excel para interpretar bonificación como porcentaje

#### 2.2 - Impuestos internos como porcentaje (en ficha producto)
**Archivo:** `migrations/028_impuestos_internos_porcentaje.sql`
- Agregar columna `impuestos_internos_porcentaje DECIMAL(5,2)` a productos
- Migrar datos: si un producto tiene `impuestos_internos` fijo y `costo_sin_iva`, calcular el % equivalente

**Archivo:** `src/types/hooks.ts`
- Agregar a `ProductoDB`: `impuestos_internos_porcentaje?: number | null`

**Archivo:** `src/components/modals/ModalProducto.tsx`
- Cambiar campo impuestos internos para que se ingrese como porcentaje
- Recalcular automáticamente el monto fijo a partir del porcentaje y el costo neto
- Label: "Imp. Internos (%)"

**Archivo:** `src/components/modals/ModalCompra.tsx`
- Al agregar producto: cargar `impuestosInternos` automáticamente desde `producto.impuestos_internos` (ya lo hace)
- Cambiar `useCalculosImpuestos` para calcular impuestos internos como porcentaje sobre el neto:
  ```
  impInt = costoUnitario * (impuestosInternos_porcentaje / 100)
  ```
- NO mostrar campo impuestos internos como editable en cada compra (se toma del producto)
- Solo mostrar el valor calculado como informativo (read-only o hidden)

**Archivo:** `src/utils/calculations.ts`
- Agregar función `calcularTotalConIvaPorcentajes(neto, pctIva, pctImpInternos)` que trabaje con porcentajes
- Mantener `calcularTotalConIva` viejo para compatibilidad

#### 2.3 - Resumen compra: mostrar bonificación
**Archivo:** `src/components/modals/ModalCompra.tsx` - sección resumen
- Agregar línea "Bonificación" al resumen de compra mostrando el descuento total aplicado
- Subtotal (antes bonif), Bonificación (descuento), Subtotal neto, IVA, Imp. Internos, Total

---

## Mejora 3: Precios mayoristas automáticos en pedidos

### Estado actual
- La lógica de resolución existe completa: `precioMayorista.ts`, `usePrecioMayorista.ts`
- `usePrecioMayorista` se llama en ModalPedido y calcula `preciosResueltos`
- La UI de ModalPedido MUESTRA los precios mayoristas correctamente (tachado + precio verde)
- Al guardar (`handleGuardarPedidoConOffline`) se aplican precios mayoristas via `aplicarPreciosMayorista()`
- Los items en el estado usan `precioUnitario` original (precio lista)
- El display calcula `precioMostrar` on-the-fly desde `preciosResueltos`

### Problema detectado
Después de investigar, el sistema de precios mayoristas **ya funciona** en cuanto a lógica:
1. Se muestra correctamente en la UI del pedido
2. Se aplica al guardar

Sin embargo, hay una discrepancia: el `total` que calcula `usePedidoFormState` usa el precio original (no el mayorista), mientras que el display usa `totalMayorista`. Esto puede generar confusión. Además, `pricingMapRef.current` en el handler podría estar vacío si la query no cargó a tiempo.

### Cambios propuestos

#### 3.1 - Asegurar que el PricingMap esté disponible al guardar
**Archivo:** `src/hooks/handlers/usePedidoHandlers.ts`
- Verificar que `pricingMapRef.current` no esté vacío antes de guardar
- Si está cargando, mostrar un loader o esperar
- Agregar log/fallback si el pricing map no está disponible

#### 3.2 - Sincronizar total mostrado con total real
**Archivo:** `src/components/modals/ModalPedido.tsx`
- El total en el footer ya muestra `totalMayorista` cuando hay precios mayoristas
- Verificar que el botón "Guardar" use el total correcto (ya lo hace via el handler)
- Esto ya funciona correctamente - solo validar el flujo end-to-end

#### 3.3 - Verificar que la query `usePricingMapQuery` se cargue correctamente
**Archivo:** `src/hooks/queries/useGruposPrecioQuery.ts`
- Verificar que `fetchPricingMap()` trae los datos correctamente de Supabase
- Asegurar que los `grupo_precio_productos` y `grupo_precio_escalas` se cargan
- Agregar manejo de error visible si la query falla

#### 3.4 - Actualizar precio en estado cuando se resuelve mayorista
**Archivo:** `src/components/modals/ModalPedido.tsx` + `usePedidoFormState.ts`
- Opción A (recomendada): Mantener estado actual (precio original en state, mayorista on-display/on-save). Es más limpio porque si el usuario saca items del grupo, el precio revierte automáticamente.
- Agregar indicador visual claro cuando un item tiene precio mayorista activo
- Asegurar que `onGuardar` incluya la resolución de precios mayoristas

#### 3.5 - Test de integración
- Crear un test que simule: agregar items de un grupo mayorista, superar el umbral, y verificar que el precio resuelto sea el correcto y se guarde correctamente

---

## Archivos impactados (resumen)

| Archivo | Mejora 1 | Mejora 2 | Mejora 3 |
|---------|----------|----------|----------|
| `migrations/027_zonas_estandarizadas.sql` | NUEVO | | |
| `migrations/028_impuestos_internos_porcentaje.sql` | | NUEVO | |
| `src/types/hooks.ts` | EDIT | EDIT | |
| `src/hooks/queries/useZonasQuery.ts` | NUEVO | | |
| `src/hooks/queries/useUsuariosQuery.ts` | EDIT | | |
| `src/hooks/queries/useClientesQuery.ts` | EDIT | | |
| `src/hooks/queries/useProveedoresQuery.ts` | EDIT | | |
| `src/hooks/queries/useGruposPrecioQuery.ts` | | | EDIT |
| `src/hooks/handlers/useUsuarioHandlers.ts` | EDIT | | |
| `src/hooks/handlers/useClienteHandlers.ts` | EDIT | | |
| `src/hooks/handlers/useProveedorHandlers.ts` | EDIT | | |
| `src/hooks/handlers/usePedidoHandlers.ts` | | | EDIT |
| `src/components/modals/ModalCliente.tsx` | EDIT | | |
| `src/components/modals/ModalUsuario.tsx` | EDIT | | |
| `src/components/modals/ModalProveedor.tsx` | EDIT | | |
| `src/components/modals/ModalCompra.tsx` | | EDIT | |
| `src/components/modals/ModalImportarCompra.tsx` | | EDIT | |
| `src/components/modals/ModalProducto.tsx` | | EDIT | |
| `src/components/modals/ModalPedido.tsx` | | | EDIT |
| `src/utils/calculations.ts` | | EDIT | |
| `src/utils/precioMayorista.ts` | | | EDIT |
| `src/hooks/usePrecioMayorista.ts` | | | EDIT |

## Orden de implementación sugerido

1. **Mejora 2** (Bonificación + Impuestos) - Es la más autocontenida, no depende de las otras
2. **Mejora 1** (Zonas) - Es la más grande, requiere migración + muchos archivos UI
3. **Mejora 3** (Precios mayoristas) - Requiere diagnóstico para confirmar el bug exacto antes de fix
