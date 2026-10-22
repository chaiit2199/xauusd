import Link from "next/link";
import type { ReactNode } from "react";

export type DeskPage = "overview" | "trading" | "news";

const links = [
  { id: "overview", href: "/", label: "Tổng quan" },
  { id: "trading", href: "/giao-dich", label: "Giao dịch" },
  { id: "news", href: "/tin-tuc", label: "Tin tức" },
];

export function SiteHeader({ active, children }: { active: DeskPage; children?: ReactNode }) {
  return (
    <>
      <a className="skip-link" href="#content">Đến nội dung chính</a>
      <header className="topbar">
        <Link href="/" className="brand" aria-label="Vàng · Trang chủ">
          <img src="/brand/symbol.svg" width="48" height="48" alt="" />
          <div><span className="brand-name">Vàng</span><span className="brand-caption">XAUUSD · GOLD TRADING</span></div>
        </Link>
        <div className="actions">{children}</div>
      </header>
      <nav className="desk-nav" aria-label="Điều hướng chính">
        {links.map((link) => <Link key={link.id} href={link.href} aria-current={active === link.id ? "page" : undefined}>{link.label}</Link>)}
      </nav>
    </>
  );
}
