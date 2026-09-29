/**
 * ModalFiltrosPedidos
 *
 * El envoltorio de CELULAR del panel de filtros de /pedidos: un bottom sheet con
 * `PanelFiltrosPedidos` adentro. En escritorio el mismo panel va en un popover
 * (ver `PedidoFilters`); el contenido es uno solo y vive en PanelFiltrosPedidos.
 *
 * Comportamiento "live": cada cambio aplica inmediatamente al estado de
 * filtros (via onFiltrosChange). El footer "Listo" cierra el sheet;
 * "Limpiar todo" resetea los siete filtros del panel a default. Búsqueda y
 * rango de fechaDesde/fechaHasta NO los toca "Limpiar todo": la búsqueda vive
 * afuera y el rango tiene su propio "Limpiar fechas de carga".
 */
import React from 'react';
import BottomSheet from '../ui/BottomSheet';
import PanelFiltrosPedidos, { PieFiltrosPedidos } from './PanelFiltrosPedidos';
import { describirFiltrosActivos, type FiltrosPedidosUI, type ParcheFiltrosPedidos } from '../../utils/filtrosPedidos';
import type { Usuario } from '../../types';

export interface ModalFiltrosPedidosProps {
  open: boolean;
  filtros: FiltrosPedidosUI;
  transportistas?: Usuario[];
  usuarios?: Usuario[];
  isAdmin: boolean;
  activosCount: number;
  onFiltrosChange: (f: ParcheFiltrosPedidos) => void;
  onClose: () => void;
}

export default function ModalFiltrosPedidos({
  open,
  filtros,
  transportistas = [],
  usuarios = [],
  isAdmin,
  activosCount,
  onFiltrosChange,
  onClose,
}: ModalFiltrosPedidosProps): React.ReactElement {
  return (
    <BottomSheet
      open={open}
      onClose={onClose}
      title="Filtros"
      description={describirFiltrosActivos(activosCount)}
      footer={
        <PieFiltrosPedidos
          activosCount={activosCount}
          onFiltrosChange={onFiltrosChange}
          onListo={onClose}
        />
      }
    >
      <PanelFiltrosPedidos
        filtros={filtros}
        transportistas={transportistas}
        usuarios={usuarios}
        isAdmin={isAdmin}
        onFiltrosChange={onFiltrosChange}
      />
    </BottomSheet>
  );
}
