# Guía de Migración: Row Level Security (RLS)

## Resumen

Esta guía explica cómo ejecutar las políticas de seguridad RLS en Supabase para proteger los datos de la aplicación Distribuidora.

## Pre-requisitos

- Acceso de administrador al proyecto en Supabase
- Backup de la base de datos (recomendado)

## Pasos de Instalación

### 1. Acceder al SQL Editor

1. Ingresar a [Supabase Dashboard](https://supabase.com/dashboard)
2. Seleccionar el proyecto de Distribuidora
3. Navegar a **SQL Editor** en el menú lateral

### 2. Ejecutar la Migración

1. Copiar el contenido del archivo `supabase/migrations/20260203_add_rls_policies.sql`
2. Pegar en el SQL Editor
3. Hacer clic en **Run** para ejecutar

### 3. Verificar la Instalación

Ejecutar la siguiente query para verificar que las políticas están activas:

```sql
SELECT
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd
FROM pg_policies
WHERE schemaname = 'public'
ORDER BY tablename, policyname;
```

Deberías ver políticas para cada tabla (clientes, pedidos, productos, etc.)

## Estructura de Permisos

### Roles y sus Accesos

| Rol | Clientes | Productos | Pedidos | Compras | Mermas |
|-----|----------|-----------|---------|---------|--------|
| **admin** | CRUD completo | CRUD completo | CRUD completo | CRUD completo | CRUD completo |
| **preventista** | CRUD | Leer | CRUD (propios) | - | - |
| **transportista** | Leer (asignados) | Leer | Leer/Actualizar (asignados) | - | Crear |
| **deposito** | - | CRUD | Leer/Actualizar (preparación) | CRUD | CRUD |

### Funciones Helper Creadas

- `get_user_role()` - Retorna el rol del usuario actual
- `is_admin()` - Verifica si el usuario es admin
- `is_preventista()` - Verifica si es admin o preventista
- `is_transportista()` - Verifica si es admin o transportista

## Tablas Protegidas

1. **perfiles** - Datos de usuarios
2. **clientes** - Información de clientes
3. **productos** - Catálogo de productos
4. **pedidos** - Órdenes de compra
5. **pedido_items** - Items de pedidos
6. **pagos** - Registros de pagos
7. **compras** - Compras a proveedores
8. **compra_items** - Items de compras
9. **proveedores** - Proveedores
10. **mermas** - Registro de mermas
11. **recorridos** - Rutas de entrega
12. **rendiciones** - Rendiciones de transportistas
13. **salvedades** - Problemas en entregas
14. **historial_pedidos** - Auditoría

## Troubleshooting

### Error: "new row violates row-level security policy"

Esto significa que el usuario no tiene permisos para la operación. Verificar:

1. Que el usuario esté autenticado (`auth.uid()` no es null)
2. Que tenga el rol correcto en la tabla `perfiles`
3. Que la operación esté permitida para su rol

### Error: "permission denied for table X"

Ejecutar:

```sql
GRANT ALL ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT USAGE ON SCHEMA public TO authenticated;
```

### Desactivar RLS temporalmente (solo para debug)

```sql
-- PELIGROSO: Solo usar en desarrollo
ALTER TABLE nombre_tabla DISABLE ROW LEVEL SECURITY;
```

Para reactivar:

```sql
ALTER TABLE nombre_tabla ENABLE ROW LEVEL SECURITY;
```

## Rollback

Si necesitas revertir los cambios:

```sql
-- Eliminar políticas
DROP POLICY IF EXISTS "policy_name" ON table_name;

-- Desactivar RLS
ALTER TABLE table_name DISABLE ROW LEVEL SECURITY;
```

## Notas Importantes

1. **No desactivar RLS en producción** - Expone todos los datos
2. **Testear con diferentes roles** - Antes de ir a producción
3. **Backup antes de cambios** - Siempre hacer backup de la BD
4. **Las políticas son acumulativas** - Un usuario puede coincidir con múltiples políticas

## Soporte

Si encuentras problemas:

1. Revisar los logs de Supabase en **Logs > Postgres**
2. Verificar que el usuario tenga perfil en la tabla `perfiles`
3. Confirmar que el rol esté correctamente asignado
