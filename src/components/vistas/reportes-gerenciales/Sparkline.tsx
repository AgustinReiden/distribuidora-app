import React from 'react'

/** Mini-tendencia en SVG inline (sin dependencias). data = serie de valores. */
export default function Sparkline({
  data,
  color = '#2563eb',
  width = 90,
  height = 24,
}: {
  data: number[]
  color?: string
  width?: number
  height?: number
}): React.ReactElement | null {
  const pts = (data ?? []).filter((n) => Number.isFinite(n))
  if (pts.length < 2) return null
  const min = Math.min(...pts)
  const max = Math.max(...pts)
  const range = max - min || 1
  const stepX = width / (pts.length - 1)
  const y = (v: number): number => height - ((v - min) / range) * height
  const path = pts
    .map((v, i) => `${i === 0 ? 'M' : 'L'}${(i * stepX).toFixed(1)},${y(v).toFixed(1)}`)
    .join(' ')
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`} aria-hidden="true" className="block">
      <path d={path} fill="none" stroke={color} strokeWidth={1.5} strokeLinejoin="round" strokeLinecap="round" />
    </svg>
  )
}
