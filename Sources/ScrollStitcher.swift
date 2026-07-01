// m_capture — independent implementation.
// SPDX-License-Identifier: MIT
import AppKit

/// Pure, UI-free engine that turns a stream of overlapping region captures into
/// one tall stitched image. It knows nothing about windows, ScreenCaptureKit, or
/// timers — feed it frames with `add(_:)`, ask for `previewImage()` while it
/// grows, and `finalImage()` when done.
///
/// How it works (all in device-pixel space, rows ordered top→bottom):
/// 1. Each row is reduced to a compact luminance *signature* (a handful of evenly
///    spaced samples) so rows can be compared cheaply with a sum-of-abs-diffs.
/// 2. **Static-band detection** compares the new frame to the previous one with no
///    vertical shift. A run of identical rows at the top is a sticky header (a
///    chat title bar, a web nav); at the bottom, a sticky footer (a message
///    composer). Those bands are frozen — captured once — and excluded from the
///    moving region so they neither duplicate nor fool the alignment.
/// 3. **Alignment** finds, within the moving region only, the vertical shift `dy`
///    where the new frame best matches the bottom of the accumulated content.
///    Only the `dy` genuinely new rows below that overlap get appended.
///
/// Confined to a single serial queue by its owner, hence `@unchecked Sendable`.
final class ScrollStitcher: @unchecked Sendable {
    enum Result {
        case noMovement       // frame identical to the last — nothing to do
        case appended(Int)    // this many new content rows were added
        case noOverlap        // couldn't align (scrolled too far/fast, or jumped)
        case capReached       // hit the maximum stitched height; stop scrolling
    }

    // MARK: Tunables (device pixels)

    private let samples = 32          // luminance samples per row signature
    private let band = 64             // rows compared when scoring an alignment
    private let maxHeightPx = 30_000  // safety ceiling on the stitched image

    /// Per-row SAD at or below this ⇒ the two rows are "the same" (static band).
    private let staticEps: Int
    /// Average per-row SAD over the band at or below this ⇒ a trusted alignment.
    private let matchEps: Int

    // MARK: Geometry

    private var width = 0
    private var rowBytes = 0
    private var sampleCols: [Int] = []
    private let previewWidth = 352

    // MARK: Frozen sticky bands (captured once, at first movement)

    private var header: [UInt8] = []; private var headerRows = 0
    private var footer: [UInt8] = []; private var footerRows = 0

    // MARK: Growing middle content

    private var content: [UInt8] = []
    private var contentSig: [UInt8] = []
    private var contentRows = 0

    // MARK: Incremental downscaled preview (width = previewWidth)

    private var previewBuf: [UInt8] = []
    private var previewRows = 0
    // Wide enough to stay sharp in the ~176pt preview panel on a 2× Retina display.

    // MARK: Previous captured frame (for static-band detection)

    private var prevBuf: [UInt8] = []
    private var prevSig: [UInt8] = []
    private var prevRows = 0

    private enum Phase { case first, awaitingMovement, stitching }
    private var phase: Phase = .first

    init() {
        staticEps = samples * 4    // ≈ 4/255 average per channel
        matchEps = samples * 14    // ≈ 14/255 average per channel
    }

    /// Total stitched height so far, in device pixels.
    var capturedHeight: Int {
        contentRows == 0 ? prevRows : headerRows + contentRows + footerRows
    }

    // MARK: Frame intake

    func add(_ cg: CGImage) -> Result {
        guard let (buf, w, h, rb) = Self.rgba(cg) else { return .noMovement }
        if width == 0 {
            width = w; rowBytes = rb
            sampleCols = (0..<samples).map { $0 * (w - 1) / max(1, samples - 1) }
        }
        guard w == width, h > band else { return .noMovement }   // region is fixed
        let sig = signatures(buf, rows: h)

        if phase == .first {
            prevBuf = buf; prevSig = sig; prevRows = h
            phase = .awaitingMovement
            return .noMovement
        }

        // 1. Static-band detection vs the previous frame (no vertical shift).
        let (rawTop, rawBot) = staticBands(sig, prevSig, rows: h)
        let rawMoving = h - rawTop - rawBot
        let minMove = max(8, h / 20)
        if rawMoving <= minMove {
            prevBuf = buf; prevSig = sig; prevRows = h
            return .noMovement
        }
        // Cap bands so a uniform page (matching margins) can't freeze most of the
        // frame as "sticky".
        let top = min(rawTop, h / 4)
        let bot = min(rawBot, h / 4)

        // 2. On the first frame that actually moved, freeze the bands and seed the
        //    content from the *pre-movement* frame (so the initial screenful's top
        //    isn't lost).
        if phase == .awaitingMovement {
            seedContent(top: top, bot: bot, h: h)
            phase = .stitching
        }

        // 3. Instantaneous direction vs the immediately-previous frame. If the view is
        //    moving up (or not at all) right now, no new content sits below the fold, so
        //    appending would only re-add rows we already have. This gate catches large
        //    reverse excursions (e.g. scrolling back toward the top after a flick) that
        //    the bounded accumulated-content search in step 4 cannot see past.
        let movingHeight = h - top - bot
        let instShift = frameShift(curSig: sig, prevSig: prevSig, top: top, movingHeight: movingHeight)

        // 4. Align this frame's moving region against the accumulated content. The shift
        //    is signed: a non-positive result means the frame already lives in `content`
        //    (scrolled up or static), so there is nothing new to append.
        let dy = align(frameSig: sig, frameTop: top, movingHeight: movingHeight)
        prevBuf = buf; prevSig = sig; prevRows = h

        if let s = instShift, s <= 0 { return .noMovement }   // moving up/static — nothing new
        guard let dy = dy else { return .noOverlap }
        if dy <= 0 { return .noMovement }                     // already in content — don't duplicate
        // New content = the bottom `dy` rows of the moving region.
        return appendRows(buf: buf, sig: sig, from: h - bot - dy, count: dy)
    }

    // MARK: Output

    /// A small, fast-to-build thumbnail of the stitch so far (grows over time).
    func previewImage() -> NSImage? {
        if previewRows > 0 { return Self.image(from: previewBuf, width: previewWidth, rows: previewRows) }
        if prevRows > 0 { return Self.image(from: prevBuf, width: width, rows: prevRows) }
        return nil
    }

    /// The full-resolution stitched image. If no scroll ever happened, returns the
    /// single captured frame (so it behaves like a plain region screenshot).
    func finalImage() -> NSImage? {
        if contentRows == 0 {
            guard prevRows > 0 else { return nil }
            return Self.image(from: prevBuf, width: width, rows: prevRows)
        }
        let totalRows = headerRows + contentRows + footerRows
        var full = [UInt8](); full.reserveCapacity(totalRows * rowBytes)
        full.append(contentsOf: header)
        full.append(contentsOf: content)
        full.append(contentsOf: footer)
        return Self.image(from: full, width: width, rows: totalRows)
    }

    // MARK: Stitch internals

    private func seedContent(top: Int, bot: Int, h: Int) {
        headerRows = top; footerRows = bot
        header = Array(prevBuf[0 ..< top * rowBytes])
        footer = Array(prevBuf[(h - bot) * rowBytes ..< h * rowBytes])
        content = Array(prevBuf[top * rowBytes ..< (h - bot) * rowBytes])
        contentSig = Array(prevSig[top * samples ..< (h - bot) * samples])
        contentRows = h - top - bot
        // Seed the preview from header + content (everything but the footer).
        previewBuf = []; previewRows = 0
        appendPreview(prevBuf, from: 0, count: h - bot)
    }

    /// Signed shift of this frame's moving top against the accumulated content, or nil
    /// if no trustworthy overlap was found. A positive result is the number of newly
    /// revealed rows (`dy`) at the bottom; a non-positive result means the frame already
    /// lives in `content` (the view scrolled up or stayed put). Searching the negative
    /// range lets the global-best match land there on a reverse scroll, so the caller can
    /// decline to append rather than be forced onto a spurious positive match — which
    /// would re-append, and thus duplicate, content we already have.
    private func align(frameSig: [UInt8], frameTop: Int, movingHeight mh: Int) -> Int? {
        let b = min(band, max(8, mh / 2))
        let maxDy = mh - b
        guard maxDy >= 1 else { return 0 }

        var bestDy = 0
        var bestScore = Int.max
        for dy in -maxDy...maxDy {
            let cs = contentRows - mh + dy        // content row aligned with frame's moving top
            if cs < 0 || cs + b > contentRows { continue }
            var s = 0
            for r in 0..<b {
                s += rowSAD(frameSig, frameTop + r, contentSig, cs + r)
                if s >= bestScore { break }       // early out
            }
            if s < bestScore { bestScore = s; bestDy = dy }
        }
        guard bestScore != Int.max, bestScore / b <= matchEps else { return nil }
        return bestDy
    }

    /// Signed vertical scroll of `cur` relative to `prev` (the immediately-previous
    /// frame) over the moving region, or nil if there's no trustworthy overlap (the view
    /// jumped too far in one frame). Positive ⇒ scrolled down by that many rows; ≤ 0 ⇒
    /// moved up or stayed put. Used as a direction gate so a reverse scroll never appends.
    private func frameShift(curSig: [UInt8], prevSig: [UInt8], top: Int, movingHeight mh: Int) -> Int? {
        let b = min(band, max(8, mh / 2))
        let maxShift = mh - b
        guard maxShift >= 1 else { return 0 }

        var bestShift = 0
        var bestScore = Int.max
        for s in -maxShift...maxShift {
            // For a downward scroll `s`, a feature at prev row p sits at cur row p - s;
            // compare a band of `b` rows that exists in both frames' moving regions.
            let curStart = top + max(0, -s)
            let prevStart = top + max(0, s)
            var sc = 0
            for r in 0..<b {
                sc += rowSAD(curSig, curStart + r, prevSig, prevStart + r)
                if sc >= bestScore { break }      // early out
            }
            if sc < bestScore { bestScore = sc; bestShift = s }
        }
        guard bestScore != Int.max, bestScore / b <= matchEps else { return nil }
        return bestShift
    }

    private func appendRows(buf: [UInt8], sig: [UInt8], from: Int, count: Int) -> Result {
        let room = maxHeightPx - (headerRows + contentRows + footerRows)
        if room <= 0 { return .capReached }
        let n = min(count, room)
        content.append(contentsOf: buf[from * rowBytes ..< (from + n) * rowBytes])
        contentSig.append(contentsOf: sig[from * samples ..< (from + n) * samples])
        contentRows += n
        appendPreview(buf, from: from, count: n)
        return n < count ? .capReached : .appended(n)
    }

    // MARK: Signatures

    private func signatures(_ buf: [UInt8], rows: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: rows * samples)
        buf.withUnsafeBufferPointer { p in
            for r in 0..<rows {
                let base = r * rowBytes
                for k in 0..<samples {
                    let i = base + sampleCols[k] * 4
                    out[r * samples + k] = UInt8((Int(p[i]) + Int(p[i + 1]) + Int(p[i + 2])) / 3)
                }
            }
        }
        return out
    }

    private func rowSAD(_ a: [UInt8], _ ra: Int, _ b: [UInt8], _ rb: Int) -> Int {
        var s = 0
        let ia = ra * samples, ib = rb * samples
        for k in 0..<samples { s += abs(Int(a[ia + k]) - Int(b[ib + k])) }
        return s
    }

    /// Length of the leading and trailing runs of rows that match (no shift).
    private func staticBands(_ cur: [UInt8], _ prev: [UInt8], rows: Int) -> (top: Int, bot: Int) {
        var top = 0
        while top < rows, rowSAD(cur, top, prev, top) <= staticEps { top += 1 }
        if top == rows { return (rows, 0) }   // whole frame static
        var bot = 0
        while bot < rows - top, rowSAD(cur, rows - 1 - bot, prev, rows - 1 - bot) <= staticEps { bot += 1 }
        return (top, bot)
    }

    // MARK: Preview downscale (horizontal box filter, width → previewWidth)

    private func appendPreview(_ buf: [UInt8], from: Int, count: Int) {
        guard width > 0, count > 0 else { return }
        let pw = previewWidth
        var rows = [UInt8](repeating: 0, count: count * pw * 4)
        buf.withUnsafeBufferPointer { p in
            for r in 0..<count {
                let srow = (from + r) * rowBytes
                for ox in 0..<pw {
                    let sx0 = ox * width / pw
                    let sx1 = max(sx0 + 1, (ox + 1) * width / pw)
                    var rr = 0, gg = 0, bb = 0, aa = 0, n = 0
                    var sx = sx0
                    while sx < sx1 {
                        let i = srow + sx * 4
                        rr += Int(p[i]); gg += Int(p[i + 1]); bb += Int(p[i + 2]); aa += Int(p[i + 3]); n += 1
                        sx += 1
                    }
                    let o = (r * pw + ox) * 4
                    rows[o] = UInt8(rr / n); rows[o + 1] = UInt8(gg / n)
                    rows[o + 2] = UInt8(bb / n); rows[o + 3] = UInt8(aa / n)
                }
            }
        }
        previewBuf.append(contentsOf: rows)
        previewRows += count
    }

    // MARK: Pixel helpers

    /// Render a CGImage into a top-down (row 0 = top) premultiplied-RGBA buffer.
    private static func rgba(_ cg: CGImage) -> (buf: [UInt8], w: Int, h: Int, rowBytes: Int)? {
        let w = cg.width, h = cg.height
        guard w > 0, h > 0 else { return nil }
        let rb = w * 4
        var data = [UInt8](repeating: 0, count: rb * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: rb, space: cs,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            // Draw without flipping: a bitmap context stores row 0 at the image's
            // top, so this yields a top-down buffer (row 0 = visual top) — the
            // orientation every routine here assumes ("rows ordered top→bottom").
            // Flipping here would make the buffer bottom-up, which silently inverts
            // the scroll-direction gate and the alignment search.
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return ok ? (data, w, h, rb) : nil
    }

    /// Build an NSImage from a top-down premultiplied-RGBA buffer. The size is set
    /// to the pixel dimensions (1×), matching `screencapture` output so the editor
    /// computes its display scale the same way it does for every other capture.
    private static func image(from buf: [UInt8], width: Int, rows: Int) -> NSImage? {
        guard width > 0, rows > 0, buf.count >= width * rows * 4 else { return nil }
        let rb = width * 4
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(buf) as CFData),
              let cg = CGImage(width: width, height: rows, bitsPerComponent: 8, bitsPerPixel: 32,
                               bytesPerRow: rb, space: cs, bitmapInfo: info, provider: provider,
                               decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        // The buffer is top-down (see `rgba`), so this CGImage is already upright —
        // wrap it directly, no flip needed.
        return NSImage(cgImage: cg, size: NSSize(width: width, height: rows))
    }
}
