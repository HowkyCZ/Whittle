import AppKit
import SwiftUI

/// Scriber's pixel mark, from a 19×19 drawing: a microphone whose grille lines follow your voice, and a
/// quill that writes while the editor works. Between them the pixels slide into a simple shape that turns,
/// then slide out into the other one. Every pixel stays on the grid and moves in straight steps.
enum PixelArt {
    struct Cell: Hashable {
        var x: Int
        var y: Int
    }

    /// The art is 19×19 on a 25×25 canvas: three pixels of room on each side.
    static let side = 19
    static let canvas = 25
    static let inset = 3
    static let center = Cell(x: 9 + inset, y: 9 + inset)

    static func cells(_ art: String) -> [Cell] {
        art.split(separator: "\n").enumerated().flatMap { y, row in
            row.enumerated().compactMap { x, c in c == "#" ? Cell(x: x + inset, y: y + inset) : nil }
        }
    }

    static let quill = cells("""
    ..........#.#.###..
    .........####.####.
    ........#######..##
    ........#####..##..
    ......#.#.#..######
    .....##.#..#######.
    ....#####....##....
    ...#####.#########.
    ...##.#.########...
    ...##..#######.....
    ...##...##.........
    .#.#.#######.......
    .###.######........
    .##.######.........
    .##.###............
    .#.#####...........
    ####...............
    .#.................
    #..................
    """)

    /// The mic with its grille rows filled; the sound lines are cut out of it each frame.
    static let micBody = cells("""
    .......#####.......
    ......#######......
    .....#########.....
    .....#########.....
    .....#########.....
    .....#########.....
    ...#.#########.#...
    ...#.#########.#...
    ...#.#########.#...
    ...#.#########.#...
    ...#.#########.#...
    ...#..#######..#...
    ...#...#####...#...
    ....#.........#....
    .....#########.....
    ........###........
    ........###........
    ........###........
    ......#######......
    """)

    /// Rows of the mic's grille (art coordinates), low voice at the top to "s" sounds at the bottom.
    static let grilleRows = [3, 5, 7, 9]

    static let muted = cells("""
    .......#####.......
    ..#...#.....#......
    ...#.#.......#.....
    ....#........#.....
    .....#.......#.....
    ......#......#.....
    ...#.#.#.....#.#...
    ...#.#..#....#.#...
    ...#.#...#...#.#...
    ...#.#....#..#.#...
    ...#.#.....#.#.#...
    ...#..#.....#..#...
    ...#...#####.#.#...
    ....#.........#....
    .....#########.#...
    ........###.....#..
    ........###......#.
    ........###........
    ......#######......
    """)

    /// The mic with each grille row's sound line at the given width (1, 3, 5 or 7).
    static func mic(lineWidths: [Int]) -> Set<Cell> {
        var cells = Set(micBody)
        for (row, width) in zip(grilleRows, lineWidths) {
            let half = (max(1, min(7, width)) - 1) / 2
            for x in (9 - half)...(9 + half) {
                cells.remove(Cell(x: x + inset, y: row + inset))
            }
        }
        return cells
    }

    /// 0…1 → 1, 3, 5 or 7.
    static func lineWidth(_ level: Double) -> Int {
        1 + 2 * min(3, max(0, Int(level * 4)))
    }

    // MARK: Shapes between the mic and the quill

    private static func everyCell(where inside: (Double, Double) -> Bool) -> [Cell] {
        var cells: [Cell] = []
        for y in 0..<canvas {
            for x in 0..<canvas where inside(Double(x - center.x), Double(y - center.y)) {
                cells.append(Cell(x: x, y: y))
            }
        }
        return cells
    }

    /// A solid square turned by `angle`: the cells whose centres fall inside it.
    static func square(side: Double, angle: Double) -> [Cell] {
        let half = side / 2
        return everyCell { dx, dy in
            let rx = dx * cos(angle) + dy * sin(angle)
            let ry = -dx * sin(angle) + dy * cos(angle)
            return abs(rx) <= half && abs(ry) <= half
        }
    }

    /// A solid disc with one notch cut in it, pointing at `angle`, so its turning shows.
    static func disc(radius: Double, notch angle: Double) -> [Cell] {
        everyCell { dx, dy in
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance <= radius else { return false }
            guard distance > 1.5 else { return true }
            var difference = atan2(dy, dx) - angle
            difference = atan2(sin(difference), cos(difference))
            return abs(difference) > 0.24
        }
    }
}

/// Works out every frame of the mark from the time, the mode and the voice. Kept outside the view so the
/// app and the preview renderer draw exactly the same frames.
final class PixelMarkEngine {
    enum Mode: Equatable {
        case listening
        case muted
        case writing
    }

    /// The shape the pixels pass through between the mic and the quill.
    enum Transition {
        case square
        case disc
    }

    typealias Cell = PixelArt.Cell

    var reduceMotion = false
    var transition: Transition = .disc
    private(set) var shown: Mode = .listening
    private var morph: (from: [Cell], to: Mode, start: Date)?
    private var rowLevels = [Double](repeating: 0, count: PixelArt.grilleRows.count)
    private var lastFrame: Date?
    private var writingSince = Date()

    static let gather: TimeInterval = 0.36
    static let turn: TimeInterval = 0.55
    static let spread: TimeInterval = 0.36
    static var morphDuration: TimeInterval { gather + turn + spread }

    /// The cells to light at `now`. `levels` is one value per grille row, 0…1, from low voice to "s" sounds.
    func cells(at now: Date, mode: Mode, levels: [Double]) -> Set<Cell> {
        let dt = min(0.1, now.timeIntervalSince(lastFrame ?? now))
        lastFrame = now
        follow(levels, dt: dt)

        if mode != shown, morph?.to != mode {
            startMorph(to: mode, at: now)
        }
        if let morph {
            let t = now.timeIntervalSince(morph.start)
            if t < Self.morphDuration {
                return morphFrame(from: morph.from, to: still(morph.to), t: t)
            }
            self.morph = nil
            shown = morph.to
            if shown == .writing { writingSince = morph.start.addingTimeInterval(Self.morphDuration) }
        }
        return frame(shown, at: now)
    }

    private func startMorph(to mode: Mode, at now: Date) {
        // Between the mic and its muted look there's nothing to travel: swap straight away.
        let travels = mode == .writing || shown == .writing
        if reduceMotion || !travels {
            shown = mode
            morph = nil
            if mode == .writing { writingSince = now }
            return
        }
        let from = morph.map { Array(morphFrame(from: $0.from, to: still($0.to), t: now.timeIntervalSince($0.start))) }
            ?? Array(frame(shown, at: now))
        morph = (from, mode, now)
    }

    private func still(_ mode: Mode) -> [Cell] {
        switch mode {
        case .writing: return PixelArt.quill
        case .muted: return PixelArt.muted
        case .listening: return Array(PixelArt.mic(lineWidths: rowLevels.map(PixelArt.lineWidth)))
        }
    }

    private func frame(_ mode: Mode, at now: Date) -> Set<Cell> {
        switch mode {
        case .listening: return PixelArt.mic(lineWidths: rowLevels.map(PixelArt.lineWidth))
        case .muted: return Set(PixelArt.muted)
        case .writing: return writingFrame(now.timeIntervalSince(writingSince))
        }
    }

    // MARK: Voice in the grille

    /// Lines open quickly and close slowly, so short sounds are still seen.
    private func follow(_ levels: [Double], dt: Double) {
        for i in rowLevels.indices {
            let target = i < levels.count ? min(1, max(0, levels[i])) : 0
            let rate = target > rowLevels[i] ? 30.0 : 7.0
            rowLevels[i] += (target - rowLevels[i]) * min(1, rate * dt)
        }
    }

    // MARK: Mic ⇄ quill

    private func shape(at progress: Double) -> [Cell] {
        switch transition {
        case .square: return PixelArt.square(side: 10, angle: .pi / 2 * ease(progress))
        case .disc: return PixelArt.disc(radius: 6.3, notch: -.pi / 2 + 2 * .pi * ease(progress))
        }
    }

    /// Pixels slide in straight steps, across then down, into the shape; it turns; they slide out again.
    private func morphFrame(from source: [Cell], to target: [Cell], t: TimeInterval) -> Set<Cell> {
        func readingOrder(_ a: Cell, _ b: Cell) -> Bool { a.y == b.y ? a.x < b.x : a.y < b.y }

        if t < Self.gather {
            let slots = shape(at: 0).sorted(by: readingOrder)
            let pixels = source.sorted(by: readingOrder)
            let p = ease(t / Self.gather)
            return Set(pixels.enumerated().map { i, cell in
                slide(from: cell, to: slots[i * slots.count / max(1, pixels.count)], p)
            })
        }
        if t < Self.gather + Self.turn {
            return Set(shape(at: (t - Self.gather) / Self.turn))
        }
        let slots = shape(at: 1).sorted(by: readingOrder)
        let pixels = target.sorted(by: readingOrder)
        let p = ease((t - Self.gather - Self.turn) / Self.spread)
        return Set(pixels.enumerated().map { i, cell in
            slide(from: slots[i * slots.count / max(1, pixels.count)], to: cell, p)
        })
    }

    /// Along the row first, then down the column, one whole cell at a time.
    private func slide(from a: Cell, to b: Cell, _ p: Double) -> Cell {
        let dx = b.x - a.x, dy = b.y - a.y
        let travelled = Int((Double(abs(dx) + abs(dy)) * p).rounded())
        if travelled <= abs(dx) {
            return Cell(x: a.x + travelled * dx.signum(), y: a.y)
        }
        return Cell(x: b.x, y: a.y + (travelled - abs(dx)) * dy.signum())
    }

    private func ease(_ x: Double) -> Double {
        let x = min(1, max(0, x))
        return x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }

    // MARK: Writing

    /// The quill moves as three pieces: the nib makes small strokes, the middle holds still like a pivot,
    /// and the top fifth leans the other way every other beat. Ink appears to the right of the nib.
    private static let poses: [(nib: Int, top: Int)] = [(0, 0), (1, 0), (1, -1), (0, -1), (-1, 0), (0, 0)]
    private static let beat: TimeInterval = 0.16

    private func writingFrame(_ t: TimeInterval) -> Set<Cell> {
        let pose = reduceMotion ? (nib: 0, top: 0) : Self.poses[Int(t / Self.beat) % Self.poses.count]
        var lit = Set<Cell>()
        for cell in PixelArt.quill {
            let row = cell.y - PixelArt.inset
            let dx = row <= 3 ? pose.top : (row >= 16 ? pose.nib : 0)
            lit.insert(Cell(x: cell.x + dx, y: cell.y))
        }
        // A seam can leave a pixel on its own; it reads as noise, so it goes.
        lit = lit.filter { cell in
            (-1...1).contains { dy in (-1...1).contains { dx in
                (dx != 0 || dy != 0) && lit.contains(Cell(x: cell.x + dx, y: cell.y + dy))
            } }
        }
        lit.formUnion(ink(t))
        return lit
    }

    private static let inkPattern = Array("###.##.####.##.###")

    private func ink(_ t: TimeInterval) -> Set<Cell> {
        guard !reduceMotion else { return [] }
        let row = PixelArt.inset + PixelArt.side - 1 + 2
        let startX = PixelArt.inset + 2
        let length = Self.inkPattern.count
        let step = Self.beat * 0.75
        let cycle = Double(length + 8) * step
        let shown = min(length, Int(t.truncatingRemainder(dividingBy: cycle) / step))
        var cells = Set<Cell>()
        for i in 0..<shown where Self.inkPattern[i] == "#" && startX + i < PixelArt.canvas {
            cells.insert(Cell(x: startX + i, y: row))
        }
        return cells
    }
}

/// The mark as a view. `levels` is the voice per grille row (low to high), 0…1; `mode` switches between
/// listening, muted and writing, and the view animates between them itself.
struct PixelMark: View {
    var mode: PixelMarkEngine.Mode
    var levels: [Double]
    var color: Color = .white
    var transition: PixelMarkEngine.Transition = .disc
    /// Points per pixel; by default the largest whole or half point that fits.
    var pixel: CGFloat? = nil

    @State private var engine = PixelMarkEngine()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // 30 frames a second is plenty for pixel steps and half the work of the display's full rate.
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            Canvas { gc, size in
                engine.reduceMotion = reduceMotion
                engine.transition = transition
                let cells = engine.cells(at: context.date, mode: mode, levels: levels)
                let unit = pixel ?? floor(min(size.width, size.height) / CGFloat(PixelArt.canvas) * 2) / 2
                // On whole device pixels, so every pixel stays sharp.
                let origin = CGPoint(x: ((size.width - unit * CGFloat(PixelArt.canvas)) / 2 * 2).rounded() / 2,
                                     y: ((size.height - unit * CGFloat(PixelArt.canvas)) / 2 * 2).rounded() / 2)
                var path = Path()
                for cell in cells {
                    path.addRect(CGRect(x: origin.x + CGFloat(cell.x) * unit, y: origin.y + CGFloat(cell.y) * unit,
                                        width: unit, height: unit))
                }
                gc.fill(path, with: .color(color))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A still pixel picture, cropped to the 19×19 art: the quill on small buttons, for example.
struct PixelGlyph: View {
    var cells: [PixelArt.Cell] = PixelArt.quill
    var color: Color
    /// Points per pixel; by default the largest whole or half point that fits.
    var pixel: CGFloat? = nil

    var body: some View {
        Canvas { gc, size in
            let side = CGFloat(PixelArt.side)
            // Whole or half points per cell keep every pixel sharp on Retina screens.
            let unit = pixel ?? max(0.5, floor(min(size.width, size.height) / side * 2) / 2)
            let origin = CGPoint(x: ((size.width - unit * side) / 2 * 2).rounded() / 2,
                                 y: ((size.height - unit * side) / 2 * 2).rounded() / 2)
            var path = Path()
            for cell in cells {
                path.addRect(CGRect(x: origin.x + CGFloat(cell.x - PixelArt.inset) * unit,
                                    y: origin.y + CGFloat(cell.y - PixelArt.inset) * unit, width: unit, height: unit))
            }
            gc.fill(path, with: .color(color))
        }
        .accessibilityHidden(true)
    }
}

extension PixelArt {
    /// The quill as a menu bar image: one point per pixel, drawn as a template so macOS tints it for
    /// light and dark menu bars.
    static func menuBarImage() -> NSImage {
        let side = CGFloat(Self.side)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
            NSColor.black.setFill()
            for cell in Self.quill {
                NSRect(x: CGFloat(cell.x - inset), y: CGFloat(cell.y - inset), width: 1, height: 1).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Whittle"
        return image
    }
}

/// "Whittle" in the pixel serif drawn on the quill's grid: 12-pixel caps, 2-pixel stems, the W's middle strokes
/// crossing and its last serif running into the h.
enum Wordmark {
    static let art = """
    ####.###..###...######..........................###..........
    .##...##...#.....#..##...........................##..........
    ..##...##.#.....#...##........##...#......#......##..........
    ..##...##.#.....#...##........##...##.....##.....##..........
    ..##....##.....#....##.............##.....##.....##..........
    ...##...##.....#....##.###...###..#####..#####...##....####..
    ...##...###...#.....####.##...##...##.....##.....##...##..##.
    ....##..###...#.....##...##...##...##.....##.....##..##....##
    ....##.#..##.#......##...##...##...##.....##.....##..########
    ....##.#..##.#......##...##...##...##.....##.....##..##......
    .....##....##.......##...##...##...##..#..##..#..##...##...#.
    .....##....##......####.####.####...###....###..####...####..
    """
    static let width = 61
    static let height = 12

    static let cells: [(x: Int, y: Int)] = art.split(separator: "\n").enumerated().flatMap { y, row in
        row.trimmingCharacters(in: .whitespaces).enumerated().compactMap { x, c in c == "#" ? (x, y) : nil }
    }
}

/// The wordmark at whole points per pixel.
struct WordmarkView: View {
    var color: Color
    var pixel: CGFloat = 1

    var body: some View {
        Canvas { gc, _ in
            var path = Path()
            for cell in Wordmark.cells {
                path.addRect(CGRect(x: CGFloat(cell.x) * pixel, y: CGFloat(cell.y) * pixel, width: pixel, height: pixel))
            }
            gc.fill(path, with: .color(color))
        }
        .frame(width: CGFloat(Wordmark.width) * pixel, height: CGFloat(Wordmark.height) * pixel)
        .accessibilityLabel("Whittle")
    }
}

/// The quill and the wordmark together, the word sitting 3 pixels above the quill's foot.
struct BrandLockup: View {
    var pixel: CGFloat = 1
    var quill: Color = Theme.accent
    var word: Color = Theme.ink

    var body: some View {
        HStack(alignment: .bottom, spacing: 5 * pixel) {
            PixelGlyph(color: quill, pixel: pixel)
                .frame(width: 19 * pixel, height: 19 * pixel)
            WordmarkView(color: word, pixel: pixel)
                .padding(.bottom, 3 * pixel)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Whittle")
    }
}
