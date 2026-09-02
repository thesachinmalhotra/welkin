import type { Metadata } from 'next'
import './globals.css'

export const metadata: Metadata = {
  title: 'Welkin — The control plane for economic events',
  description: 'A configuration and composition layer for event-driven economic processing and archival.',
}

export default function RootLayout({ children }: Readonly<{ children: React.ReactNode }>) {
  return <html lang="en" className="bg-background"><body>{children}</body></html>
}
