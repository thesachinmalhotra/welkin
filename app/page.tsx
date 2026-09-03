'use client'

import { useEffect, useState } from 'react'
import {
  ArrowUpRight,
  Box,
  ChevronRight,
  Command,
  GitBranch,
  Layers3,
  Menu,
  Search,
  ShieldCheck,
  Workflow,
  X,
} from 'lucide-react'

const navItems = ['Overview', 'Architecture', 'Verification']

const pipeline = [
  { icon: GitBranch, eyebrow: 'Input', title: 'Any producer', detail: 'Stripe, HTTP, Kafka' },
  { icon: Workflow, eyebrow: 'Boundary', title: 'OpenMeter Collector', detail: 'Normalize once' },
  { icon: Box, eyebrow: 'Contract', title: 'Canonical CloudEvent', detail: 'The platform event' },
]

function Mark() {
  return <span className="mark" aria-hidden="true"><span /><span /><span /></span>
}

export default function Home() {
  const [paletteOpen, setPaletteOpen] = useState(false)
  const [mobileOpen, setMobileOpen] = useState(false)

  useEffect(() => {
    const onKeyDown = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k') {
        event.preventDefault()
        setPaletteOpen(true)
      }
      if (event.key === 'Escape') setPaletteOpen(false)
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
  }, [])

  const goTo = (id: string) => {
    setPaletteOpen(false)
    document.getElementById(id)?.scrollIntoView({ behavior: 'smooth' })
  }

  return (
    <main id="top" className="site-shell">
      <header className="site-header">
        <a className="brand" href="#top" aria-label="Welkin home"><Mark /><span>welkin</span></a>
        <nav className="desktop-nav" aria-label="Primary navigation">
          {navItems.map((item, index) => <a key={item} href={`#${['top', 'architecture', 'evidence'][index]}`}>{item}</a>)}
        </nav>
        <div className="header-actions">
          <button className="search-trigger" onClick={() => setPaletteOpen(true)} aria-label="Open command menu"><Search data-icon="inline-start" /><span>Search documentation</span><kbd>⌘ K</kbd></button>
          <button className="menu-trigger" onClick={() => setMobileOpen(!mobileOpen)} aria-label="Toggle navigation">{mobileOpen ? <X /> : <Menu />}</button>
          <a className="header-link" href="#evidence">View verification <ArrowUpRight data-icon="inline-end" /></a>
        </div>
      </header>

      {mobileOpen && <nav className="mobile-nav" aria-label="Mobile navigation">{navItems.map((item, index) => <a key={item} href={`#${['top', 'architecture', 'evidence'][index]}`} onClick={() => setMobileOpen(false)}>{item}<ChevronRight /></a>)}</nav>}

      <section className="hero">
        <div className="eyebrow"><span className="status-dot" /> Architecture reference <span className="eyebrow-divider">/</span> Verification in progress</div>
        <h1>Infrastructure for<br />economic events.</h1>
        <p className="hero-copy">Welkin defines how usage events enter a system, become canonical, and move independently to billing and archival destinations.</p>
        <div className="hero-actions"><button className="primary-button" onClick={() => setPaletteOpen(true)}><Command data-icon="inline-start" /> Explore the architecture <kbd>⌘ K</kbd></button><a className="text-button" href="#architecture">Read the architecture <ArrowUpRight data-icon="inline-end" /></a></div>
        <div className="hero-meta"><span>OPEN SOURCE ARCHITECTURE</span><span>STATUS / IN PROGRESS</span></div>
      </section>

      <section id="architecture" className="architecture section-rule">
        <div className="section-heading"><div><div className="section-index">01</div><h2>One event.<br />Two independent planes.</h2></div><p>Normalize at the Collector boundary.<br />Keep downstream systems independent.</p></div>
        <div className="pipeline" aria-label="Welkin event pipeline">
          {pipeline.map((item, index) => { const Icon = item.icon; return <div className="pipeline-step" key={item.title}><div className="pipeline-card"><div className="icon-box"><Icon /></div><div><div className="card-eyebrow">{item.eyebrow}</div><h3>{item.title}</h3><p>{item.detail}</p></div></div>{index < pipeline.length - 1 && <ChevronRight className="pipeline-arrow" />}</div> })}
        </div>
        <div className="planes"><article className="plane-card economic"><div className="plane-top"><span className="plane-icon"><Layers3 /></span><span>Economic Plane</span><span className="plane-state">independent</span></div><h3>Usage becomes revenue.</h3><p>OpenMeter consumes the canonical event and maps usage to native Stripe billing. Failures in the Archive Plane do not interrupt this path.</p><a href="#evidence">Read about the Economic Plane <ArrowUpRight data-icon="inline-end" /></a></article><article className="plane-card archive"><div className="plane-top"><span className="plane-icon"><Box /></span><span>Archive Plane</span><span className="plane-state">independent</span></div><h3>Events remain queryable.</h3><p>The broker routes the same event to durable object storage through Kafka and Parquet, without coupling archival reliability to billing.</p><a href="#evidence">Read about the Archive Plane <ArrowUpRight data-icon="inline-end" /></a></article></div>
      </section>

      <section id="evidence" className="evidence section-rule"><div className="section-heading"><div><div className="section-index">02</div><h2>Verification is<br />part of the product.</h2></div><p>Documented boundaries, explicit status,<br />and no unsupported claims.</p></div><div className="evidence-list"><div className="evidence-row"><div><span className="row-kicker">Gate 1</span><h3>Architecture and operating model</h3><p>Canonical boundaries and failure isolation are documented.</p></div><span className="badge partial">Partial</span></div><div className="evidence-row"><div><span className="row-kicker">Gate 2</span><h3>Runtime verification</h3><p>End-to-end ingestion, billing, and archival evidence is next.</p></div><span className="badge next">Next</span></div><div className="evidence-row"><div><span className="row-kicker">Principle</span><h3>Evidence over assertion</h3><p>Welkin surfaces only behavior verified at the system boundary.</p></div><ShieldCheck className="row-check" /></div></div></section>

      <footer className="site-footer"><a className="brand" href="#top"><Mark /><span>welkin</span></a><span>Configuration for economic event systems.</span></footer>

      {paletteOpen && <div className="palette-backdrop" role="dialog" aria-modal="true" aria-label="Welkin command menu" onClick={() => setPaletteOpen(false)}><div className="palette" onClick={event => event.stopPropagation()}><div className="palette-search"><Search /><input autoFocus placeholder="Search or jump to..." /><kbd>ESC</kbd></div><div className="palette-label">QUICK ACTIONS</div><button onClick={() => goTo('architecture')}><Workflow /><span><strong>Explore canonical flow</strong><small>View Welkin&apos;s event model</small></span><kbd>↵</kbd></button><button onClick={() => goTo('evidence')}><ShieldCheck /><span><strong>Open architecture status</strong><small>Review current evidence</small></span><kbd>↵</kbd></button></div></div>}
    </main>
  )
}
