# Migraciones de Base de Datos

Este directorio contiene las migraciones SQL para la base de datos de Supabase.

## Cómo aplicar las migraciones

### Opción 1: Desde Supabase Dashboard (Recomendado)

1. Accede a tu proyecto en [Supabase Dashboard](https://app.supabase.com)
2. Ve a la sección **SQL Editor**
3. Abre el archivo `001_add_pedido_improvements.sql`
4. Copia y pega el contenido completo en el editor SQL
5. Ejecuta la consulta haciendo clic en "Run"

### Opción 2: Usando Supabase CLI

```bash
# Si tienes Supabase CLI instalado
supabase db push
```

## Migraciones disponibles

### 001_add_pedido_improvements.sql

**Fecha:** 2025-12-31

**Descripción:** Mejoras en la funcionalidad de pedidos

**Cambios:**
- Agrega campo `notas` a tabla pedidos (observaciones para preparación)
- Agrega campo `forma_pago` a tabla pedidos (efectivo, transferencia, etc.)
- Agrega campo `estado_pago` a tabla pedidos (pendiente, pagado, parcial)
- Crea tabla `pedido_historial` para auditoría de cambios
- Crea triggers automáticos para registrar cambios en pedidos

**Funcionalidades nuevas:**
- Historial completo de cambios en cada pedido (quién cambió qué y cuándo)
- Observaciones/notas en pedidos para el equipo de preparación
- Gestión de forma de pago y estado de pago

## Verificar que las migraciones se aplicaron correctamente

Ejecuta las siguientes consultas en el SQL Editor de Supabase:

```sql
-- Verificar que los campos se agregaron correctamente
SELECT column_name, data_type, column_default
FROM information_schema.columns
WHERE table_name = 'pedidos'
AND column_name IN ('notas', 'forma_pago', 'estado_pago');

-- Verificar que la tabla de historial existe
SELECT EXISTS (
  SELECT FROM information_schema.tables
  WHERE table_name = 'pedido_historial'
);

-- Ver los triggers creados
SELECT trigger_name, event_manipulation, event_object_table
FROM information_schema.triggers
WHERE event_object_table = 'pedidos';
```

## Rollback (Revertir cambios)

Si necesitas revertir los cambios de la migración `001_add_pedido_improvements.sql`:

```sql
-- Eliminar triggers
DROP TRIGGER IF EXISTS trigger_registrar_cambio_pedido ON pedidos;
DROP TRIGGER IF EXISTS trigger_registrar_creacion_pedido ON pedidos;

-- Eliminar funciones
DROP FUNCTION IF EXISTS registrar_cambio_pedido();
DROP FUNCTION IF EXISTS registrar_creacion_pedido();

-- Eliminar tabla de historial
DROP TABLE IF EXISTS pedido_historial;

-- Eliminar columnas de pedidos
ALTER TABLE pedidos
DROP COLUMN IF EXISTS notas,
DROP COLUMN IF EXISTS forma_pago,
DROP COLUMN IF EXISTS estado_pago;
```
