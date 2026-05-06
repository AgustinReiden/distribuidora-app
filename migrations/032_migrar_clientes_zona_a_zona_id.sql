-- Migration 032: Completar la migración clientes.zona (texto) → clientes.zona_id (FK a zonas)
--
-- Estado al momento de aplicar (verificado en main): la tabla `zonas` ya existe con
-- RLS habilitado y 3 policies (mt_zonas_insert, mt_zonas_select, mt_zonas_update)
-- ya con la semántica correcta (admin para mutaciones, select por sucursal). Faltan:
--  1. La policy DELETE.
--  2. El UNIQUE constraint actual es `UNIQUE(nombre)` GLOBAL, lo cual contradice
--     el modelo multi-sucursal (sucursal_id NOT NULL en la tabla). Lo corregimos
--     a `UNIQUE(nombre, sucursal_id)` para que dos sucursales puedan tener
--     una zona "Centro" cada una sin colisionar.
--
-- Hay 16 zonas existentes (todas en sucursal_id=1); 261 de 268 clientes con zona
-- ya tienen zona_id seteado — solo 7 quedan por backfill (1 en sucursal=2, 6 en
-- sucursal=1 que probablemente nunca fueron procesados por una migración anterior).
--
-- Esta migración:
--  1. Cambia UNIQUE(nombre) → UNIQUE(nombre, sucursal_id) en zonas.
--  2. Agrega la policy mt_zonas_delete que falta (admin-only por sucursal).
--  3. Crea las zonas faltantes (las que existen como texto en clientes pero no
--     en zonas para esa sucursal).
--  4. Backfillea zona_id de los clientes restantes (case-insensitive match).
--  5. Marca clientes.zona como deprecada (comentario; no se borra para rollback).
--
-- La vista `bot_clientes_huerfanos_visibles` NO existe en este schema (fue eliminada
-- en una migración posterior), por lo que el plan original de recrearla no aplica.

-- 1. Cambiar UNIQUE constraint a (nombre, sucursal_id)
ALTER TABLE public.zonas DROP CONSTRAINT IF EXISTS zonas_nombre_unique;
ALTER TABLE public.zonas DROP CONSTRAINT IF EXISTS zonas_nombre_sucursal_unique;
ALTER TABLE public.zonas
  ADD CONSTRAINT zonas_nombre_sucursal_unique UNIQUE (nombre, sucursal_id);

-- 2. Policy DELETE faltante en zonas
DROP POLICY IF EXISTS mt_zonas_delete ON public.zonas;
CREATE POLICY mt_zonas_delete ON public.zonas
  FOR DELETE TO authenticated
  USING (es_admin() AND sucursal_id = current_sucursal_id());

-- 3. Insertar zonas únicas que existen como texto en clientes pero no en zonas
INSERT INTO public.zonas (nombre, sucursal_id, activo)
SELECT DISTINCT trim(c.zona), c.sucursal_id, true
FROM public.clientes c
WHERE c.zona IS NOT NULL
  AND trim(c.zona) <> ''
  AND NOT EXISTS (
    SELECT 1 FROM public.zonas z
    WHERE lower(trim(z.nombre)) = lower(trim(c.zona))
      AND z.sucursal_id = c.sucursal_id
  );

-- 4. Backfill clientes.zona_id desde clientes.zona (case-insensitive match)
UPDATE public.clientes c
SET zona_id = z.id
FROM public.zonas z
WHERE c.zona_id IS NULL
  AND c.zona IS NOT NULL
  AND lower(trim(z.nombre)) = lower(trim(c.zona))
  AND z.sucursal_id = c.sucursal_id;

-- 5. Marcar deprecación de clientes.zona (no se borra; rollback safe)
COMMENT ON COLUMN public.clientes.zona IS
  'DEPRECADO desde 2026-05-05 — usar zona_id (FK a zonas). Se mantiene un release para rollback seguro.';
