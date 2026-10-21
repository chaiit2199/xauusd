import type { Article } from "../../lib/types";
import { when } from "../../lib/format";

type NewsListProps = {
  articles: Article[];
  title: string;
  empty: string;
};

export function NewsList({ articles, title, empty }: NewsListProps) {
  return (
    <section className="panel news-panel">
      <div className="panel-head">
        <h2>{title}</h2>
        <p>{articles.length} bài</p>
      </div>
      {articles.length === 0 ? (
        <p className="empty">{empty}</p>
      ) : (
        <ul className="news-list">
          {articles.map((article) => {
            const headline = article.title_vi || article.title;

            return (
              <li key={article.url}>
                <a href={article.url} target="_blank" rel="noreferrer" title={article.title}>
                  <span className="news-source">{article.source}</span>
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
