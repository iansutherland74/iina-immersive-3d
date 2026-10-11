//
//  LiveCaptionOverlay.swift
//  iina
//
//  Copyright (C) 2026 the IINA Immersive 3D contributors.
//  Based on IINA, Copyright (C) 2017-2026 Collider LI and contributors.
//  Licensed under the GNU General Public License, version 3.
//
//  mpv draws subtitles into the frame the stereo shader shifts, so one caption
//  line would be split across the two eyes. While Play on Glasses is showing
//  side-by-side 3D, the same line is drawn at the bottom of each eye instead.

import Cocoa

final class LiveCaptionOverlay {
  let host = LiveCaptionHost()

  func setText(_ text: String) {
    host.setCaption(text)
  }

  func attachIfNeeded() {
    guard !PlayerCore.playerCores.isEmpty, let main = PlayerCore.active.mainWindow else { return }
    guard main.loaded, let container = main.videoViewContainer else { return }
    if host.superview !== container {
      host.removeFromSuperview()
      host.translatesAutoresizingMaskIntoConstraints = false
      container.addSubview(host)
      NSLayoutConstraint.activate([
        host.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        host.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        host.topAnchor.constraint(equalTo: container.topAnchor),
        host.bottomAnchor.constraint(equalTo: container.bottomAnchor)
      ])
    }
    let anchor = main.videoView.superview === container ? main.videoView : nil
    container.addSubview(host, positioned: .above, relativeTo: anchor)
    host.needsLayout = true
  }

  func remove() {
    host.setCaption("")
    host.removeFromSuperview()
  }
}

final class LiveCaptionHost: NSView {
  private let panes = [LiveCaptionPane(), LiveCaptionPane()]
  private(set) var caption = ""

  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    for pane in panes {
      pane.translatesAutoresizingMaskIntoConstraints = true
      pane.autoresizingMask = []
      addSubview(pane)
    }
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func setCaption(_ text: String) {
    caption = text
    let show = !text.isEmpty && IPTVLiveOverlayController.duplicatesEyes && bounds.width >= 640
    isHidden = !show
    needsLayout = true
    for pane in panes {
      pane.needsDisplay = true
    }
  }

  override func layout() {
    super.layout()
    let duplicate = IPTVLiveOverlayController.duplicatesEyes && bounds.width >= 640
    let slots = duplicate ? 2 : 1
    let width = bounds.width / CGFloat(slots)
    for (index, pane) in panes.enumerated() {
      let shown = !caption.isEmpty && index < slots && width >= 32 && bounds.height >= 32
      pane.isHidden = !shown
      if shown {
        pane.frame = NSRect(x: CGFloat(index) * width, y: 0, width: width, height: bounds.height)
      }
      pane.needsDisplay = true
    }
    isHidden = caption.isEmpty || !duplicate
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }
}

final class LiveCaptionPane: NSView {
  override var isFlipped: Bool { true }
  override var isOpaque: Bool { false }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func hitTest(_ point: NSPoint) -> NSView? {
    nil
  }

  override func draw(_ dirtyRect: NSRect) {
    NSColor.clear.setFill()
    dirtyRect.fill()
    guard let host = superview as? LiveCaptionHost else { return }
    let text = host.caption.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, bounds.width > 40, bounds.height > 40 else { return }

    let scale = min(1, max(0.62, bounds.width / 1920))
    let font = NSFont.systemFont(ofSize: max(22, 40 * scale), weight: .semibold)
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    style.lineBreakMode = .byWordWrapping
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
    shadow.shadowOffset = NSSize(width: 0, height: -1)
    shadow.shadowBlurRadius = 2
    let attributes: [NSAttributedString.Key: Any] = [
      .font: font,
      .foregroundColor: NSColor.white,
      .paragraphStyle: style,
      .shadow: shadow
    ]
    let horizontal = max(16, 28 * scale)
    let maxWidth = max(40, bounds.width - horizontal * 2)
    let measured = (text as NSString).boundingRect(
      with: NSSize(width: maxWidth, height: bounds.height * 0.4),
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: attributes
    )
    let reserve: CGFloat = GlassesEyeControls.shared.shown ? 100 : 36
    let padX: CGFloat = 16 * scale
    let padY: CGFloat = 8 * scale
    let boxWidth = min(maxWidth, ceil(measured.width) + padX * 2)
    let boxHeight = min(bounds.height * 0.45, ceil(measured.height) + padY * 2)
    let box = NSRect(
      x: (bounds.width - boxWidth) / 2,
      y: max(8, bounds.height - boxHeight - reserve),
      width: boxWidth,
      height: boxHeight
    )
    NSColor.black.withAlphaComponent(0.62).setFill()
    NSBezierPath(roundedRect: box, xRadius: 10, yRadius: 10).fill()
    let textRect = box.insetBy(dx: padX, dy: padY)
    (text as NSString).draw(with: textRect, options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: attributes)
  }
}
