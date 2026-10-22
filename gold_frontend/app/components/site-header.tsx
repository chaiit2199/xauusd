import Link from "next/link";
import type { ReactNode } from "react";

export function SiteHeader({ children }: { children?: ReactNode }) {
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

    </>
  );
}
