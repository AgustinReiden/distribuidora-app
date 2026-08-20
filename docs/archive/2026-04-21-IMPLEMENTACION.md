# Guía de Implementación - Mejoras en Pedidos

Este documento detalla las mejoras implementadas en el sistema de pedidos y cómo aplicarlas.

## 📋 Resumen de Mejoras Implementadas

### 1. **Notas/Observaciones en Pedidos**
- Campo de texto libre para agregar observaciones importantes
- Útil para instrucciones de preparación, detalles de entrega, etc.
- Se muestra destacado en la vista de pedidos

### 2. **Forma de Pago**
- Opciones: Efectivo, Transferencia, Cheque, Cuenta Corriente, Tarjeta
- Se muestra con ícono en cada pedido
- Permite rastrear el método de pago preferido del cliente

### 3. **Estado de Pago**
- Estados: Pendiente, Pagado, Parcial
- Badge de color en cada pedido (rojo/amarillo/verde)
- Facilita el seguimiento de cobranzas

### 4. **Historial de Cambios**
- Auditoría completa de todos los cambios en pedidos
- Registra: quién, qué, cuándo
- Botón "Historial" en cada pedido
- Triggers automáticos en la base de datos

### 5. **Reportes por Preventista**
- Nueva sección "Reportes" en el menú (solo admins)
- Métricas por vendedor:
  - Total de ventas
  - Cantidad de pedidos
  - Estados de pedidos (pendiente/asignado/entregado)
  - Total pagado vs pendiente
- Filtros por rango de fechas
- Tabla con totales generales

---

## 🚀 Pasos de Implementación

### Paso 1: Aplicar Migración de Base de Datos

**IMPORTANTE:** Esta migración debe aplicarse **antes** de desplegar el código del frontend.

#### Opción A: Desde Supabase Dashboard (Recomendado)

1. Accede a tu proyecto en [Supabase Dashboard](https://app.supabase.com)
2. Ve a la sección **SQL Editor**
3. Abre el archivo `migrations/001_add_pedido_improvements.sql`
4. Copia y pega el contenido completo en el editor SQL
5. Ejecuta la consulta haciendo clic en "Run"
6. Verifica que se ejecutó correctamente (sin errores)

#### Opción B: Usando Supabase CLI

```bash
# Si tienes Supabase CLI instalado
supabase db push
```

#### Verificar que la migración se aplicó correctamente

Ejecuta estas consultas en el SQL Editor:

```sql
-- Verificar nuevos campos en pedidos
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'pedidos'
AND column_name IN ('notas', 'forma_pago', 'estado_pago');

-- Verificar que existe la tabla de historial
SELECT EXISTS (
  SELECT FROM information_schema.tables
  WHERE table_name = 'pedido_historial'
);

-- Ver los triggers creados
SELECT trigger_name, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE event_object_table = 'pedidos';
```

### Paso 2: Desplegar el Frontend

El código ya está en el branch `claude/add-order-history-notes-Qi942`.

1. **Hacer merge del branch:**
   ```bash
   git checkout main
   git merge claude/add-order-history-notes-Qi942
   git push origin main
   ```

2. **O crear un Pull Request en GitHub:**
   - Ve a: https://github.com/AgustinReiden/distribuidora-app/pull/new/claude/add-order-history-notes-Qi942
   - Revisa los cambios
   - Crea y aprueba el PR
   - Haz merge

3. **Si usas deploy automático** (Vercel, Netlify, etc.):
   - El deploy se ejecutará automáticamente al hacer merge a main
   - Espera a que finalice el deploy

4. **Si despliegas manualmente**:
   ```bash
   npm install  # Por si hay nuevas dependencias
   npm run build
   # Sube la carpeta dist/ a tu servidor
   ```

### Paso 3: Probar las Nuevas Funcionalidades

#### 3.1 Probar Creación de Pedido con Notas y Pago

1. Ingresa como Admin o Preventista
2. Ve a "Pedidos" → "Nuevo"
3. Completa un pedido normalmente
4. **Agrega una nota** en el campo "Notas / Observaciones"
5. Selecciona **Forma de Pago** (ej: Transferencia)
6. Selecciona **Estado de Pago** (ej: Pagado)
7. Confirma el pedido
8. Verifica que se muestra correctamente en la lista

#### 3.2 Probar Historial de Cambios

1. Selecciona un pedido existente
2. Haz clic en el botón **"Historial"**
3. Deberías ver el evento de creación
4. Asigna un transportista o cambia el estado
5. Vuelve a abrir el historial
6. Verifica que se registró el cambio con tu nombre y timestamp

#### 3.3 Probar Edición de Pedido

1. En cualquier pedido, haz clic en **"Editar"**
2. Modifica las notas, forma de pago o estado de pago
3. Guarda los cambios
4. Verifica que se actualizó en la lista
5. Abre el historial y confirma que se registraron los cambios

#### 3.4 Probar Reportes por Preventista

1. Ingresa como Admin
2. Ve a la nueva sección **"Reportes"** en el menú
3. Opcionalmente selecciona un rango de fechas
4. Haz clic en **"Generar Reporte"**
5. Verifica que muestra:
   - Lista de preventistas
   - Total de ventas por preventista
   - Cantidad de pedidos
   - Desglose por estados
   - Total pagado vs pendiente
   - Fila de totales generales

---

## 📝 Notas Importantes

### Compatibilidad

- ✅ **Todos los pedidos existentes** seguirán funcionando normalmente
- ✅ Los campos nuevos (`notas`, `forma_pago`, `estado_pago`) tienen valores por defecto
- ✅ El historial solo registrará cambios desde la fecha de implementación
- ✅ No se requieren cambios en pedidos existentes

### Permisos por Rol

| Funcionalidad | Admin | Preventista | Transportista |
|---------------|-------|-------------|---------------|
| Ver historial | ✅ | ✅ | ✅ |
| Editar pedido | ✅ | ✅ | ❌ |
| Ver reportes | ✅ | ❌ | ❌ |
| Crear pedido con notas/pago | ✅ | ✅ | ❌ |

### Valores por Defecto

- **notas**: vacío (NULL)
- **forma_pago**: "efectivo"
- **estado_pago**: "pendiente"

---

## 🔧 Troubleshooting

### Error al aplicar la migración

**Problema:** Error "column already exists"

**Solución:** Es probable que la columna ya exista. Verifica con:
```sql
SELECT column_name FROM information_schema.columns
WHERE table_name = 'pedidos' AND column_name = 'notas';
```

Si existe, puedes omitir ese ALTER TABLE específico.

---

### El historial no registra cambios

**Problema:** Los cambios no aparecen en el historial

**Verificar:**
1. Que los triggers estén activos:
```sql
SELECT * FROM information_schema.triggers
WHERE event_object_table = 'pedidos';
```

2. Ejecuta manualmente un cambio y verifica:
```sql
UPDATE pedidos SET estado = 'asignado' WHERE id = 1;
SELECT * FROM pedido_historial WHERE pedido_id = 1;
```

---

### Los reportes están vacíos

**Problema:** La vista de reportes no muestra datos

**Verificar:**
1. Que existan pedidos con `usuario_id` asignado
2. Que la tabla `perfiles` tenga usuarios con rol 'preventista' o 'admin'
3. Intenta sin filtros de fecha primero

---

## 🔄 Rollback (Revertir Cambios)

Si necesitas revertir las migraciones de base de datos:

```sql
-- 1. Eliminar triggers
DROP TRIGGER IF EXISTS trigger_registrar_cambio_pedido ON pedidos;
DROP TRIGGER IF EXISTS trigger_registrar_creacion_pedido ON pedidos;

-- 2. Eliminar funciones
DROP FUNCTION IF EXISTS registrar_cambio_pedido();
DROP FUNCTION IF EXISTS registrar_creacion_pedido();

-- 3. Eliminar tabla de historial
DROP TABLE IF EXISTS pedido_historial;

-- 4. Eliminar columnas de pedidos
ALTER TABLE pedidos
DROP COLUMN IF EXISTS notas,
DROP COLUMN IF EXISTS forma_pago,
DROP COLUMN IF EXISTS estado_pago;
```

**Para el frontend:** simplemente haz rollback al commit anterior:
```bash
git revert 1bc30c8
git push origin main
```

---

## 📞 Soporte

Si tienes problemas con la implementación:
1. Revisa los logs del SQL Editor en Supabase
2. Verifica la consola del navegador para errores de JavaScript
3. Asegúrate de que las variables de entorno estén correctas
4. Consulta el archivo `migrations/README.md` para más detalles sobre las migraciones

---

## ✅ Checklist de Implementación

- [ ] Migración SQL aplicada en Supabase
- [ ] Verificación de campos nuevos en tabla `pedidos`
- [ ] Verificación de tabla `pedido_historial` creada
- [ ] Triggers verificados
- [ ] Código frontend desplegado
- [ ] Prueba de creación de pedido con notas/pago
- [ ] Prueba de visualización de historial
- [ ] Prueba de edición de pedido
- [ ] Prueba de reportes por preventista
- [ ] Verificación en producción

¡Implementación completada! 🎉
