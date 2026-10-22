"use client";

import { useState } from "react";
import type { Article } from "../../lib/types";
import { when } from "../../lib/format";

type NewsListProps = {
  articles: Article[];
  title: string;
  empty: string;
  filterable?: boolean;
};

export function NewsList({ articles, title, empty, filterable = false }: NewsListProps) {
  const [impact, setImpact] = useState("all");
  const visible = !filterable || impact === "all" ? articles : articles.filter((article) =>
    impact === "unknown" ? !article.impact : article.impact === impact,
  );
  return (
    <section className="panel news-panel">
      <div className="panel-head">
        <h2>{title}</h2>
        <p>{visible.length} bài</p>
      </div>
      {filterable ? <div className="news-filters">
        <label htmlFor="news-impact">Mức tác động</label>
        <select id="news-impact" value={impact} onChange={(event) => setImpact(event.target.value)}>
          <option value="all">Tất cả</option><option value="High">Cao · High</option><option value="Medium">Trung bình · Medium</option><option value="Low">Thấp · Low</option><option value="unknown">Chưa phân loại</option>
        </select>
        {articles.every((article) => !article.impact) ? <span>Nguồn tin hiện chưa cung cấp mức tác động cho bài viết.</span> : null}
      </div> : null}
      {visible.length === 0 ? (
        <p className="empty">{articles.length === 0 ? empty : "Chưa có bài viết được phân loại ở mức tác động này."}</p>
      ) : (
        <ul className="news-list">
          {visible.map((article) => {
            const headline = article.title_vi || article.title;

            return (
              <li key={article.url}>
                <a href={article.url} target="_blank" rel="noreferrer" title={article.title}>
                  <span className="news-source">{article.source}{filterable ? <small className="impact-label">{article.impact === "High" ? "Tác động cao" : article.impact === "Medium" ? "Tác động trung bình" : article.impact === "Low" ? "Tác động thấp" : "Chưa phân loại"}</small> : null}</span>
                  <span className="news-title">{headline}</span>
                  <time dateTime={article.published_at ?? undefined}>{when(article.published_at)}</time>
                </a>
              </li>
            );
          })}
        </ul>
      )}
    </section>
  );
}
