# Auditoría Integral del Código

Fecha: 2026-03-20
Proyecto: `distribuidora-app`
Alcance: frontend React/Vite, capa de datos actual y legacy, SQL/RPC/RLS y tooling que impacta la confiabilidad de los checks

## Resumen Ejecutivo

La aplicación tiene buena cobertura base para cambios locales (`tsc` y `vitest` pasan), pero la auditoría encontró varios problemas reales en flujos críticos de pedidos, sincronización offline y dashboard:

- Riesgo inmediato de falso éxito al aplicar ordenes de entrega y al editar pedidos.
- Riesgo inmediato de duplicación de operaciones offline por una deduplicación que hoy no funciona.
- Riesgo funcional en dashboard por cache incorrecto de métricas personalizadas.
- Riesgo estructural de escalabilidad por analytics y exportaciones basadas en cargas completas de tablas.
- Riesgo de regresión por deriva entre la capa viva y la capa legacy de pedidos.

## Validación Ejecutada

- `npm.cmd run typecheck`
  Resultado: OK
- `npm.cmd run test:run`
  Resultado: OK, 27 archivos y 522 tests en verde
- `npx.cmd eslint src e2e eslint.config.js`
  Resultado: OK
- `npm.cmd run lint`
  Resultado: no es confiable hoy porque recorre artefactos generados en `.claude/worktrees/*/dist`

## Top Riesgos Inmediatos

1. Aplicar una ruta optimizada puede mostrar éxito sin persistir nada.
2. La cola offline puede aceptar duplicados y luego sincronizarlos como pedidos/mermas repetidos.
3. Editar un pedido puede cerrar el modal con mensaje de éxito aunque el backend rechace el cambio.

## Hallazgos

### 1. [Alta] La acción "Aplicar orden" usa una RPC inexistente y además ignora el error de Supabase

- Categoría: funcionalidad / lógica de negocio
- Evidencia:
  - `src/components/containers/PedidosContainer.tsx:469-480` llama `supabase.rpc('actualizar_orden_entrega', ...)` y luego siempre ejecuta `notify.success('Orden de entrega actualizado')`.
  - `migrations/006_add_orden_entrega_rpc.sql:25-66` solo define `actualizar_orden_entrega_batch(...)` y `limpiar_orden_entrega(...)`.
- Impacto:
  - El usuario puede creer que persistió la ruta optimizada cuando la base quedó igual.
  - La operación afecta un flujo operativo central para transportistas.
- Condición de disparo:
  - Desde gestión de rutas, al confirmar un orden optimizado.
- Recomendación:
  - Cambiar el handler para usar `actualizar_orden_entrega_batch`.
  - Inspeccionar explícitamente `{ error }` antes de cerrar modal o mostrar éxito.

### 2. [Alta] La deduplicación offline no funciona porque el hash cambia en cada intento

- Categoría: funcionalidad / lógica de negocio
- Evidencia:
  - `src/lib/offlineDb.ts:138-147` agrega `Date.now()` al hash usado para detectar duplicados.
  - `src/lib/offlineDb.ts:159-170` compara hashes exactos para decidir si una operación ya existe.
  - `src/hooks/useOfflineSync.ts:350-353` agrega el pedido al estado local antes de conocer si el encolado fue aceptado o rechazado.
  - `e2e/offline-sync.spec.ts:193-233` tiene un test de duplicados, pero solo imprime el resultado y no hace ninguna aserción.
- Impacto:
  - Dos clics iguales offline pueden terminar como dos operaciones distintas y sincronizarse duplicadas.
  - También pueden aparecer pendientes "fantasma" en la UI si el encolado falla o debería descartarse.
- Condición de disparo:
  - Reintentos manuales, doble submit, reconexiones o clicks repetidos en modo offline.
- Recomendación:
  - Hacer el hash determinístico a partir de `type + payload normalizado`.
  - No meter timestamps dentro del hash.
  - Persistir en la UI solo después de confirmar que la operación fue encolada.
  - Convertir el test e2e de duplicados en una aserción obligatoria.

### 3. [Alta] Editar un pedido puede reportar éxito aunque el backend no haya guardado nada

- Categoría: funcionalidad
- Evidencia:
  - `src/components/containers/PedidosContainer.tsx:379-392` hace `await supabase.from('pedidos').update(...).eq(...)`, pero nunca inspecciona el `error` devuelto.
  - Ese mismo flujo cierra el modal y lanza `notify.success('Pedido actualizado')` sin invalidar cache.
  - En contraste, `src/components/containers/PedidosContainer.tsx:402-413` sí valida `error` e invalida queries cuando edita items.
- Impacto:
  - Notas, estado de pago o monto pagado pueden fallar por RLS/validación/red y aun así presentarse como guardados.
  - Incluso cuando el update sí persiste, la lista puede seguir mostrando datos viejos hasta un refresh.
- Condición de disparo:
  - Editar un pedido desde `ModalEditarPedido`.
- Recomendación:
  - Capturar `{ error }` y abortar el camino de éxito si existe.
  - Invalidar `pedidosKeys.all` o al menos refrescar la query paginada visible.

### 4. [Media] El dashboard reutiliza cache incorrecta para rangos personalizados

- Categoría: funcionalidad
- Evidencia:
  - `src/components/containers/DashboardContainer.tsx:30-39` pasa `fechaDesde` y `fechaHasta` a `useMetricasQuery`.
  - `src/hooks/queries/useMetricasQuery.ts:20-21` construye la key solo con `periodo` y `usuarioId`.
  - `src/hooks/queries/useMetricasQuery.ts:262-263` usa esa key aunque la query sí depende de `fechaDesde` y `fechaHasta`.
- Impacto:
  - Si el usuario cambia un rango personalizado dentro del mismo período, React Query puede devolver la métrica anterior durante el `staleTime`.
  - El dashboard muestra cifras equivocadas sin indicar que la fecha cambió.
- Condición de disparo:
  - Cambiar fechas dentro del modo `personalizado`.
- Recomendación:
  - Incluir `fechaDesde` y `fechaHasta` en `metricasKeys.dashboard(...)`.

### 5. [Media] "Limpiar pedidos offline" no limpia realmente la cola persistida

- Categoría: funcionalidad
- Evidencia:
  - `src/hooks/useOfflineSync.ts:614-618` promete limpiar todo, pero llama `cleanupOldOperations(0)`.
  - `src/lib/offlineDb.ts:281-290` solo elimina operaciones con `status = 'completed'`.
- Impacto:
  - Operaciones `pending` o `failed` pueden reaparecer después de recargar la app.
  - El operador no tiene una forma real de descartar una cola corrupta o vieja.
- Condición de disparo:
  - Uso de la acción de limpieza esperando resetear la cola offline.
- Recomendación:
  - Agregar una operación explícita para borrar pendientes/fallidas, o borrar por tipo/usuario según el caso de uso.

### 6. [Media] El dashboard y los backups cargan tablas completas en el navegador

- Categoría: escalabilidad
- Evidencia:
  - `src/hooks/queries/useMetricasQuery.ts:57-65` trae todos los pedidos con cliente e items.
  - `src/hooks/queries/useMetricasQuery.ts:114-178` calcula filtros, top productos, top clientes y series temporales enteramente en cliente.
  - `src/hooks/supabase/useBackup.ts:93-103` exporta `clientes`, `productos` y `pedidos` completos desde el frontend.
- Impacto:
  - El dashboard se degrada con el crecimiento histórico de pedidos.
  - Los backups completos dependen de memoria y ancho de banda del navegador del admin.
- Condición de disparo:
  - Historial mediano/grande de pedidos o backups operados desde equipos modestos.
- Recomendación:
  - Mover agregaciones de métricas a RPC/SQL.
  - Paginación o generación server-side para exportaciones grandes.
  - Reducir los `select` a los campos realmente usados.

### 7. [Media] Hay deriva fuerte entre la capa viva y la capa legacy de pedidos

- Categoría: lógica de negocio / mantenibilidad
- Evidencia:
  - `src/types/index.ts:86-92` define `EstadoPedido` con `en_reparto`.
  - `src/types/hooks.ts:90` usa `en_camino` y `asignado`.
  - `src/services/api/pedidoService.ts:183-210` valida `en_reparto` y asigna ese estado.
  - `src/hooks/queries/usePedidosQuery.ts:114` filtra `['asignado', 'en_camino']`.
  - `src/services/api/pedidoService.ts:120-139` trabaja con `fecha_creacion`, `metodo_pago` y un filtro `cliente.zona` marcado como TODO, mientras la capa viva usa otro contrato.
  - `src/services/api/pedidoService.ts:264-286` escribe/ordena historial con columnas `accion`, `descripcion` y `fecha`, pero la tabla real usa `campo_modificado`, `valor_anterior`, `valor_nuevo` y `created_at` según `migrations/001_add_pedido_improvements.sql:17-25`.
- Impacto:
  - La capa legacy ya no representa fielmente el contrato real de la base ni el flujo actual.
  - Reutilizarla para nuevos features o fixes puede reintroducir bugs difíciles de detectar.
- Condición de disparo:
  - Cualquier refactor que mezcle servicios legacy con containers/query hooks actuales.
- Recomendación:
  - Consolidar un único contrato de estados y columnas.
  - Retirar o encapsular la capa legacy para que no compita con la viva.

## Hallazgos Descartados o Reinterpretados

- El posible descalce entre `productoService` y las RPC de stock no quedó como bug inmediato:
  - `src/services/api/productoService.ts:113-117` llama `descontar_stock_atomico` con `p_items`.
  - Las firmas JSONB siguen definidas en `migrations/023_security_fixes.sql:69-169`.
  - `migrations/032_fix_rpc_security_and_add_fecha_pedido.sql` agrega overloads escalares, pero no elimina las firmas JSONB anteriores.
  - Conclusión: hoy es más bien deuda de contrato y no una rotura confirmada.

- El lint del repo no está “roto” a nivel de código fuente:
  - `npx.cmd eslint src e2e eslint.config.js` pasa limpio.
  - El problema de `npm run lint` viene de alcance/ignore, no de errores reales del `src`.

## Riesgos Estructurales Secundarios

- `eslint.config.js:10` solo ignora `dist` y `**/*.d.ts`, por lo que worktrees o builds auxiliares fuera de la raíz contaminan el comando estándar de lint.
- La suite e2e actual existe, pero varias pruebas de caos validan muy poco el estado final y por eso no protegen bien los invariantes offline más delicados.

## Siguiente Fase Recomendada

1. Corregir los tres hallazgos altos antes de tocar optimizaciones menores.
2. Unificar el contrato de pedidos y desactivar la capa legacy no usada.
3. Mover métricas y exportaciones pesadas fuera del navegador para sostener crecimiento.
