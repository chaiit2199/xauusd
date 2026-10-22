"use client";

import { useState } from "react";
import type { CalendarEvent } from "../../lib/types";
import { when } from "../../lib/format";

export function EconomicEvents({ events }: { events: CalendarEvent[] }) {
  const [impact, setImpact] = useState("all");
  const visible = impact === "all" ? events : events.filter((event) => event.impact === impact);
  return (
    <section className="panel">
      <div className="panel-head"><h2>Lịch kinh tế · USD</h2><span className="connection-label">24 giờ tới</span></div>
      <div className="news-filters"><label htmlFor="event-impact">Mức tác động</label><select id="event-impact" value={impact} onChange={(event) => setImpact(event.target.value)}><option value="all">Tất cả</option><option value="High">Cao · High</option><option value="Medium">Trung bình · Medium</option></select></div>
      {visible.length ? <ul className="event-list">{visible.map((event) => <li key={`${event.time}-${event.title}`}><time dateTime={event.time}>{when(event.time)}</time><strong>{event.title}</strong><span className="pill warn">{event.impact === "High" ? "Cao" : event.impact === "Medium" ? "Trung bình" : event.impact}</span></li>)}</ul> : <p className="empty">Chưa có sự kiện trong dữ liệu nhận được ở mức tác động này.</p>}
      <p className="basis">Nguồn hiện chỉ cung cấp một số sự kiện USD tác động cao, gồm sự kiện vừa công bố trong 30 phút gần nhất.</p>
    </section>
  );
}
