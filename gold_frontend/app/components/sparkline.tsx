type SparklineProps = {
  values: number[];
};

export function Sparkline({ values }: SparklineProps) {
  if (values.length < 2) return null;

  const width = 640;
  const height = 140;
  const min = Math.min(...values);
  const max = Math.max(...values);
  const span = max - min || 1;
  const rising = values[values.length - 1] >= values[0];

  const line = values
    .map((value, index) => {
      const x = (index / (values.length - 1)) * width;
      const y = height - ((value - min) / span) * (height - 16) - 8;
      return `${index === 0 ? "M" : "L"}${x.toFixed(2)} ${y.toFixed(2)}`;
    })
    .join(" ");

  const lastX = width;
  const lastY = height - ((values[values.length - 1] - min) / span) * (height - 16) - 8;

  return (
    <svg className="spark" viewBox={`0 0 ${width} ${height}`} role="img" aria-label="Biểu đồ giá 5 ngày">
      <path d={`${line} L${width} ${height} L0 ${height} Z`} className={rising ? "spark-fill up" : "spark-fill down"} />
      <path d={line} className={rising ? "spark-line up" : "spark-line down"} />
      <circle cx={lastX} cy={lastY} r="4.5" className={rising ? "spark-dot up" : "spark-dot down"} />
    </svg>
  );
}
