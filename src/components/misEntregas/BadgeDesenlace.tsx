import { memo } from 'react'
import { LABEL_DESENLACE, ESTILO_DESENLACE, type Desenlace } from '../../constants/desenlacePedido'

interface Props {
  desenlace: Desenlace
}

function BadgeDesenlace({ desenlace }: Props) {
  const estilo = ESTILO_DESENLACE[desenlace] ?? ESTILO_DESENLACE.pendiente
  const Icon = estilo.icon

  return (
    <span
      className={`inline-flex items-center gap-1 px-1.5 py-0.5 rounded text-xs font-medium ${estilo.badge}`}
    >
      <Icon className="w-3 h-3" aria-hidden="true" />
      {LABEL_DESENLACE[desenlace] ?? desenlace}
    </span>
  )
}

export default memo(BadgeDesenlace)
