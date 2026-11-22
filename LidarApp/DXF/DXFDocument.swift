import Foundation

/// Minimalny generator DXF R12 (AC1009) – czytany przez AutoCAD, Civil 3D, IntelliCAD, ArCADię, BricsCAD itd.
struct DXFDocument {
    private var lines: [String] = []

    static func num(_ v: Double) -> String { String(format: "%.4f", v) }

    /// Teksty w DXF R12: bez polskich znaków (transliteracja), żeby nie było „krzaczków”.
    static func ascii(_ text: String) -> String {
        let map: [Character: String] = [
            "ą": "a", "ć": "c", "ę": "e", "ł": "l", "ń": "n", "ó": "o", "ś": "s", "ź": "z", "ż": "z",
            "Ą": "A", "Ć": "C", "Ę": "E", "Ł": "L", "Ń": "N", "Ó": "O", "Ś": "S", "Ź": "Z", "Ż": "Z",
            "–": "-", "—": "-", "°": "deg"
        ]
        var out = ""
        for ch in text {
            if let r = map[ch] {
                out += r
            } else if ch.isASCII, ch != "\n", ch != "\r" {
                out.append(ch)
            } else if ch == "\n" || ch == "\r" {
                out += " "
            }
        }
        return out
    }

    private mutating func add(_ code: Int, _ value: String) {
        lines.append(String(code))
        lines.append(value)
    }

    private mutating func add(_ code: Int, _ value: Double) {
        add(code, Self.num(value))
    }

    private mutating func entity(_ type: String, layer: String, color: Int) {
        add(0, type)
        add(8, Self.ascii(layer))
        add(62, String(color))
    }

    mutating func line(_ x1: Double, _ y1: Double, _ z1: Double,
                       _ x2: Double, _ y2: Double, _ z2: Double,
                       layer: String, color: Int) {
        entity("LINE", layer: layer, color: color)
        add(10, x1); add(20, y1); add(30, z1)
        add(11, x2); add(21, y2); add(31, z2)
    }

    mutating func circle(x: Double, y: Double, z: Double, radius: Double, layer: String, color: Int) {
        entity("CIRCLE", layer: layer, color: color)
        add(10, x); add(20, y); add(30, z)
        add(40, radius)
    }

    mutating func point(x: Double, y: Double, z: Double, layer: String, color: Int) {
        entity("POINT", layer: layer, color: color)
        add(10, x); add(20, y); add(30, z)
    }

    mutating func text(_ text: String, x: Double, y: Double, z: Double = 0,
                       height: Double, rotation: Double = 0, layer: String, color: Int) {
        entity("TEXT", layer: layer, color: color)
        add(10, x); add(20, y); add(30, z)
        add(40, height)
        add(1, Self.ascii(text))
        if rotation != 0 { add(50, rotation) }
    }

    /// $INSUNITS = 6 (metry).
    func build() -> String {
        var out: [String] = [
            "0", "SECTION", "2", "HEADER",
            "9", "$ACADVER", "1", "AC1009",
            "9", "$INSUNITS", "70", "6",
            "0", "ENDSEC",
            "0", "SECTION", "2", "ENTITIES"
        ]
        out.append(contentsOf: lines)
        out.append(contentsOf: ["0", "ENDSEC", "0", "EOF"])
        return out.joined(separator: "\n") + "\n"
    }
}
