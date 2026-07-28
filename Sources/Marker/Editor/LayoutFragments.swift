import AppKit

/// Shared, mutable rendering context referenced by every decoration.
///
/// Kept as a class so decorations stay tiny and a theme change is a single
/// assignment rather than a rewrite of every attribute run.
final class StyleContext {
    var theme: Theme
    var containerWidth: CGFloat = 0
    var monoAdvance: CGFloat = 0

    /// Appearance-resolved values for the offscreen renderer, which has no
    /// NSAppearance of its own and needs concrete colors.
    var isDark = false
    var textColorHex = "#000000"
    var backgroundHex = "#ffffff"
    var codeBackgroundHex = "#f5f5f7"

    /// Folder the current document lives in, for resolving relative image paths.
    var documentDirectory: URL?

    init(theme: Theme) {
        self.theme = theme
    }
}

struct CodeBlockDecoration {
    var isFirst: Bool
    var isLast: Bool
    var language: String?
}

struct BulletDecoration {
    /// The number to draw for ordered items, e.g. "3." Unordered items draw a shape.
    var text: String
    /// Right edge (text left margin) the bullet is laid out against.
    var contentX: CGFloat
    var isOrdered: Bool
    var checkbox: Bool
    var checked: Bool
    /// Nesting level, which selects the marker shape.
    var depth: Int
}

/// A diagram, equation or image occupying a whole block.
struct RenderedBlock {
    var image: NSImage?
    /// Space the line reserves for it, in points.
    var size: CGSize
    var centered: Bool
    /// Shown instead of the image when a render failed.
    var message: String?
}

/// A rendered run sitting inside a line of prose.
///
/// Horizontal space is reserved by kerning the concealed source, so the glyph
/// run is drawn at the character position rather than inserted into the text.
struct InlineRenderable {
    /// Index of the anchor character, relative to this paragraph's start.
    var characterIndex: Int
    var image: NSImage?
    var size: CGSize
}

/// Per-paragraph drawing instructions, attached as a text attribute.
final class BlockDecoration: NSObject {
    let context: StyleContext
    var codeBlock: CodeBlockDecoration?
    var thematicBreak = false
    var headingRuleLevel: Int?
    var quoteDepth = 0
    var bullet: BulletDecoration?
    var renderedBlock: RenderedBlock?
    var renderedTable: RenderedTable?
    var tableSelection: [CGRect] = []
    var inlineRenderables: [InlineRenderable] = []
    /// Focus mode dims the text via attributes; drawn chrome has to match.
    var dimmed = false

    init(context: StyleContext) {
        self.context = context
    }

    var isEmpty: Bool {
        codeBlock == nil && !thematicBreak && headingRuleLevel == nil
            && quoteDepth == 0 && bullet == nil
            && renderedBlock == nil && renderedTable == nil && inlineRenderables.isEmpty
    }
}

extension NSAttributedString.Key {
    /// Drawing instructions consumed by `DecoratedLayoutFragment`.
    static let blockDecoration = NSAttributedString.Key("MarkerBlockDecoration")
    /// Marks a range as a concealed syntax marker (used for caret skipping).
    static let concealedMarker = NSAttributedString.Key("MarkerConcealed")
    /// Link destination for a rendered Markdown link.
    static let markdownLink = NSAttributedString.Key("MarkerMarkdownLink")
    /// Range of a task-list checkbox, so clicks can toggle it.
    static let taskCheckbox = NSAttributedString.Key("MarkerTaskCheckbox")
}

final class DecoratedLayoutFragment: NSTextLayoutFragment {

    private var decoration: BlockDecoration? {
        guard let paragraph = textElement as? NSTextParagraph else { return nil }
        let string = paragraph.attributedString
        guard string.length > 0 else { return nil }
        return string.attribute(.blockDecoration, at: 0, effectiveRange: nil) as? BlockDecoration
    }

    override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard let decoration, !decoration.isEmpty else { return base }
        // Decorations are drawn against the text container's left edge, which sits
        // `layoutFragmentFrame.minX` to the left of this fragment's own origin.
        let leftReach = layoutFragmentFrame.minX + 48
        let expanded = CGRect(x: -leftReach,
                              y: base.minY - 12,
                              width: leftReach + decoration.context.containerWidth + 48,
                              height: base.height + 24)
        return base.union(expanded)
    }

    override func draw(at point: CGPoint, in context: CGContext) {
        if let decoration, !decoration.isEmpty {
            drawDecoration(decoration, at: point, in: context)
        }
        super.draw(at: point, in: context)
    }

    private func drawDecoration(_ decoration: BlockDecoration,
                                at point: CGPoint,
                                in context: CGContext) {
        let theme = decoration.context.theme
        let width = decoration.context.containerWidth
        let frame = layoutFragmentFrame
        // `point` is this fragment's origin; the container's origin is further left
        // by however much the paragraph is indented.
        let originX = point.x - frame.minX
        let rect = CGRect(x: originX, y: point.y, width: width, height: frame.height)

        context.saveGState()
        defer { context.restoreGState() }
        if decoration.dimmed { context.setAlpha(0.32) }

        // --- fenced / indented code background --------------------------------
        if let code = decoration.codeBlock {
            // Each line paints its own slice of the block. Overlap adjacent slices
            // by a point so fractional line heights can't leave hairline seams.
            let bleedTop: CGFloat = code.isFirst ? 0 : 1
            let bleedBottom: CGFloat = code.isLast ? 0 : 1
            let box = CGRect(x: rect.minX,
                             y: rect.minY - bleedTop,
                             width: width,
                             height: rect.height + bleedTop + bleedBottom)
            context.addPath(roundedPath(box,
                                        radius: 6,
                                        roundTop: code.isFirst,
                                        roundBottom: code.isLast))
            context.setFillColor(theme.codeBackground.cgColor)
            context.fillPath()
        }

        // --- blockquote bars ---------------------------------------------------
        if decoration.quoteDepth > 0 {
            context.setFillColor(theme.quoteBar.cgColor)
            for level in 0..<decoration.quoteDepth {
                let x = rect.minX + CGFloat(level) * theme.quoteIndent + 1
                context.fill(CGRect(x: x, y: rect.minY, width: 3, height: rect.height))
            }
        }

        // --- thematic break ----------------------------------------------------
        if decoration.thematicBreak {
            context.setFillColor(theme.rule.cgColor)
            let y = rect.midY.rounded()
            context.fill(CGRect(x: rect.minX, y: y, width: width, height: 1))
        }

        // --- heading underline for H1 / H2 -------------------------------------
        if let level = decoration.headingRuleLevel, level <= 2 {
            context.setFillColor(theme.rule.cgColor)
            let y = (rect.maxY - theme.baseSize * 0.30).rounded()
            context.fill(CGRect(x: rect.minX, y: y, width: width, height: 1))
        }

        // --- list bullets, numbers, checkboxes ---------------------------------
        if let bullet = decoration.bullet {
            drawBullet(bullet, theme: theme, rect: rect, in: context)
        }

        // --- laid-out table ----------------------------------------------------
        if let table = decoration.renderedTable {
            table.draw(at: CGPoint(x: rect.minX, y: rect.minY + theme.baseSize * 0.3),
                       theme: theme,
                       selection: decoration.tableSelection,
                       in: context)
        }

        // --- rendered diagram, equation or image -------------------------------
        if let block = decoration.renderedBlock {
            drawRenderedBlock(block, theme: theme, rect: rect, in: context)
        }
        for renderable in decoration.inlineRenderables {
            drawInlineRenderable(renderable, theme: theme, at: point, in: context)
        }
    }

    private func drawRenderedBlock(_ block: RenderedBlock,
                                   theme: Theme,
                                   rect: CGRect,
                                   in context: CGContext) {
        let box = CGRect(x: block.centered
                            ? rect.minX + (rect.width - block.size.width) / 2
                            : rect.minX,
                         y: rect.minY + (rect.height - block.size.height) / 2,
                         width: block.size.width,
                         height: block.size.height)

        if let message = block.message {
            context.setFillColor(theme.codeBackground.cgColor)
            context.addPath(CGPath(roundedRect: box, cornerWidth: 6, cornerHeight: 6,
                                   transform: nil))
            context.fillPath()
            let text = NSAttributedString(string: message, attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: round(theme.baseSize * 0.8),
                                                   weight: .regular),
                .foregroundColor: theme.synRemoved,
            ])
            draw(text, at: CGPoint(x: box.minX + 10, y: box.minY + 8), in: context)
            return
        }

        guard let image = block.image else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawInlineRenderable(_ renderable: InlineRenderable,
                                      theme: Theme,
                                      at point: CGPoint,
                                      in context: CGContext) {
        guard let image = renderable.image else { return }
        guard let line = textLineFragments.first(where: {
            NSLocationInRange(renderable.characterIndex, $0.characterRange)
                || NSMaxRange($0.characterRange) == renderable.characterIndex
        }) ?? textLineFragments.first else { return }

        let local = line.locationForCharacter(at: renderable.characterIndex)
        let bounds = line.typographicBounds
        let baseline = bounds.minY + line.glyphOrigin.y
        let box = CGRect(x: point.x + bounds.minX + local.x,
                         // Sit the run on the text baseline, like a glyph would.
                         y: point.y + baseline - renderable.size.height + theme.baseSize * 0.12,
                         width: renderable.size.width,
                         height: renderable.size.height)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        image.draw(in: box, from: .zero, operation: .sourceOver, fraction: 1,
                   respectFlipped: true, hints: [.interpolation: NSImageInterpolation.high.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ text: NSAttributedString, at origin: CGPoint, in context: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        text.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func drawBullet(_ bullet: BulletDecoration,
                            theme: Theme,
                            rect: CGRect,
                            in context: CGContext) {
        // Center on the text's x-height rather than the line box: with a line
        // height multiple the extra leading sits above the glyphs, so a box-center
        // marker reads as floating too high.
        let centerY: CGFloat
        if let line = textLineFragments.first {
            let baseline = line.typographicBounds.minY + line.glyphOrigin.y
            centerY = rect.minY + baseline - theme.baseSize * 0.26
        } else {
            centerY = rect.midY
        }
        let gap = theme.baseSize * 0.5

        if !bullet.checkbox, !bullet.isOrdered {
            // Draw the marker as a shape rather than a glyph so it stays crisp
            // and keeps a consistent weight at every nesting depth.
            let radius = theme.baseSize * 0.145
            let center = CGPoint(x: rect.minX + bullet.contentX - gap - radius, y: centerY)
            let box = CGRect(x: center.x - radius, y: center.y - radius,
                             width: radius * 2, height: radius * 2)
            context.setFillColor(theme.accent.cgColor)
            context.setStrokeColor(theme.accent.cgColor)
            context.setLineWidth(1.5)
            switch bullet.depth % 3 {
            case 0:
                context.fillEllipse(in: box)
            case 1:
                context.strokeEllipse(in: box.insetBy(dx: 0.5, dy: 0.5))
            default:
                context.fill(box.insetBy(dx: 0.6, dy: 0.6))
            }
            return
        }

        if bullet.checkbox {
            let side = theme.baseSize * 0.82
            let box = CGRect(x: rect.minX + bullet.contentX - side - gap * 0.8,
                             y: centerY - side / 2,
                             width: side, height: side)
            let path = CGPath(roundedRect: box, cornerWidth: 4, cornerHeight: 4,
                              transform: nil)
            if bullet.checked {
                context.addPath(path)
                context.setFillColor(theme.accent.cgColor)
                context.fillPath()

                context.setStrokeColor(NSColor.white.cgColor)
                context.setLineWidth(2)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.move(to: CGPoint(x: box.minX + side * 0.24, y: box.midY + side * 0.02))
                context.addLine(to: CGPoint(x: box.minX + side * 0.43, y: box.midY + side * 0.22))
                context.addLine(to: CGPoint(x: box.minX + side * 0.76, y: box.midY - side * 0.22))
                context.strokePath()
            } else {
                context.addPath(path)
                context.setStrokeColor(theme.marker.cgColor)
                context.setLineWidth(1.5)
                context.strokePath()
            }
            return
        }

        let attributed = NSAttributedString(string: bullet.text, attributes: [
            .font: NSFont.systemFont(ofSize: round(theme.baseSize * 0.88), weight: .regular),
            .foregroundColor: theme.secondaryText,
        ])
        let size = attributed.size()
        let origin = CGPoint(x: rect.minX + bullet.contentX - size.width - gap * 0.8,
                             y: centerY - size.height / 2)

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        attributed.draw(at: origin)
        NSGraphicsContext.restoreGraphicsState()
    }

    private func roundedPath(_ rect: CGRect,
                             radius: CGFloat,
                             roundTop: Bool,
                             roundBottom: Bool) -> CGPath {
        let path = CGMutablePath()
        let r = min(radius, rect.height / 2)
        let topLeft = CGPoint(x: rect.minX, y: rect.minY)
        let topRight = CGPoint(x: rect.maxX, y: rect.minY)
        let bottomRight = CGPoint(x: rect.maxX, y: rect.maxY)
        let bottomLeft = CGPoint(x: rect.minX, y: rect.maxY)

        path.move(to: CGPoint(x: topLeft.x, y: topLeft.y + (roundTop ? r : 0)))
        if roundTop {
            path.addArc(tangent1End: topLeft, tangent2End: topRight, radius: r)
        } else {
            path.addLine(to: topLeft)
        }
        path.addLine(to: CGPoint(x: topRight.x - (roundTop ? r : 0), y: topRight.y))
        if roundTop {
            path.addArc(tangent1End: topRight, tangent2End: bottomRight, radius: r)
        } else {
            path.addLine(to: topRight)
        }
        path.addLine(to: CGPoint(x: bottomRight.x, y: bottomRight.y - (roundBottom ? r : 0)))
        if roundBottom {
            path.addArc(tangent1End: bottomRight, tangent2End: bottomLeft, radius: r)
        } else {
            path.addLine(to: bottomRight)
        }
        path.addLine(to: CGPoint(x: bottomLeft.x + (roundBottom ? r : 0), y: bottomLeft.y))
        if roundBottom {
            path.addArc(tangent1End: bottomLeft, tangent2End: topLeft, radius: r)
        } else {
            path.addLine(to: bottomLeft)
        }
        path.closeSubpath()
        return path
    }
}
