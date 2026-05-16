-- Agrega un campo opcional para que el repartidor reciba contexto extra sobre
-- la entrega (ej "tocar timbre azul", "fondo del pasillo"). Es distinto a
-- `notas`, que sirve para info general del cliente; este campo se imprime
-- en la hoja de ruta y se ve en la vista web del transportista.
ALTER TABLE clientes
  ADD COLUMN IF NOT EXISTS aclaracion_direccion TEXT;

COMMENT ON COLUMN clientes.aclaracion_direccion IS
  'Texto extra para repartidores sobre como llegar a la direccion (ej "tocar timbre azul", "fondo del pasillo"). Se imprime en hoja de ruta y se muestra en VistaRutaTransportista.';
