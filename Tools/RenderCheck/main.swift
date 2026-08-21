import AppKit
import SwiftTerm

// Offscreen render probe: renders CJK text in a real window (Retina backing,
// incremental redraws, SGR colors) and writes a PNG plus a per-cell map so
// wide-character artifacts are visible without running the app.

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 560, height: 130))

let size: CGFloat = 13
let base = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
let cascade = ["PingFang SC", "PingFang TC", "Hiragino Sans GB", "Heiti SC"].map { family in
    NSFontDescriptor(fontAttributes: [.family: family, .size: size])
}
view.font = NSFont(
    descriptor: base.fontDescriptor.addingAttributes([.cascadeList: cascade]),
    size: size
) ?? base

view.nativeForegroundColor = NSColor(calibratedWhite: 0.88, alpha: 1)
view.nativeBackgroundColor = NSColor(calibratedRed: 0.09, green: 0.10, blue: 0.12, alpha: 1)

let window = NSWindow(
    contentRect: view.frame,
    styleMask: [.titled],
    backing: .buffered,
    defer: false
)
window.contentView = view
window.orderBack(nil)

// Incremental feeds so partial dirty-rect redraws are exercised.
let lines = [
    "总用量 397364\r\n",
    "-rw-r--r-- 1 root root 45599 8月  20 23:53 报文.txt\r\n",
    "\u{1b}[1;31mml训练指令.txt\u{1b}[0m 后跟英文 tail\r\n",
    "\u{1b}[34m目录\u{1b}[0m 中\u{1b}[7m反显\u{1b}[0m尾\r\n",
]
for line in lines {
    view.feed(text: line)
    view.display()
}

let scale = window.backingScaleFactor
guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    fatalError("no rep")
}
view.cacheDisplay(in: view.bounds, to: rep)

if let png = rep.representation(using: .png, properties: [:]) {
    try png.write(to: URL(fileURLWithPath: "Tools/RenderCheck/out.png"))
}

let cols = view.terminal.cols
let rows = view.terminal.rows
let cellWidth = view.bounds.width / CGFloat(cols)
let cellHeight = view.bounds.height / CGFloat(rows)
let pxScale = CGFloat(rep.pixelsWide) / view.bounds.width

func brightness(_ color: NSColor?) -> CGFloat {
    guard let c = color?.usingColorSpace(.deviceRGB) else { return 0 }
    return (c.redComponent + c.greenComponent + c.blueComponent) / 3
}

print("backingScale=\(scale) px=\(rep.pixelsWide)x\(rep.pixelsHigh) cols=\(cols) rows=\(rows)")
print("legend: '#' = cell is >60% near-white (a solid block artifact)")

for row in 0..<min(rows, 5) {
    var map = ""
    for col in 0..<min(cols, 40) {
        var filled = 0
        var samples = 0
        let x0 = CGFloat(col) * cellWidth * pxScale
        let y0 = CGFloat(row) * cellHeight * pxScale
        var y = y0 + 1
        while y < y0 + cellHeight * pxScale - 1 {
            var x = x0 + 1
            while x < x0 + cellWidth * pxScale - 1 {
                if brightness(rep.colorAt(x: Int(x), y: Int(y))) > 0.7 { filled += 1 }
                samples += 1
                x += 1
            }
            y += 1
        }
        let ratio = samples == 0 ? 0 : Double(filled) / Double(samples)
        map.append(ratio > 0.6 ? "#" : (ratio > 0.2 ? "O" : (ratio > 0.02 ? "o" : ".")))
    }
    print("row \(row): |\(map)|")
}
