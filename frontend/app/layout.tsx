import type { Metadata } from "next";
import { DM_Sans } from "next/font/google";
import "./globals.css";
import { APP_NAME, TAGLINE } from "@/lib/brand";
import { Providers } from "./providers";
import Header from "@/components/Header";

const sans = DM_Sans({ subsets: ["latin"], variable: "--font-sans" });

export const metadata: Metadata = {
  title: `${APP_NAME}: ${TAGLINE}`,
  description: "Add rules to your Uniswap v4 liquidity: take profit, stop loss, follow the price, compound. Limit orders too.",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={sans.variable}>
      <body>
        <Providers>
          <Header />
          <main>{children}</main>
        </Providers>
      </body>
    </html>
  );
}
