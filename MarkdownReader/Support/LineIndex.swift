import Foundation

/// UTF-16 offsets of line starts, for fast line <-> character mapping.
/// Line breaks are LF, CRLF or CR, matching the Markdown parser.
struct LineIndex {
    let starts: [Int]
    let length: Int

    init(_ string: NSString) {
        length = string.length
        var starts = [0]
        starts.reserveCapacity(length / 40 + 1)
        let chunkSize = 16_384
        var buffer = [unichar](repeating: 0, count: chunkSize)
        var location = 0
        var previousWasCR = false
        while location < length {
            let count = min(chunkSize, length - location)
            buffer.withUnsafeMutableBufferPointer { ptr in
                string.getCharacters(ptr.baseAddress!, range: NSRange(location: location, length: count))
                for i in 0..<count {
                    let c = ptr[i]
                    if c == 0x0A {
                        if previousWasCR {
                            // CRLF: the line start recorded after CR moves past LF.
                            starts[starts.count - 1] = location + i + 1
                        } else {
                            starts.append(location + i + 1)
                        }
                        previousWasCR = false
                    } else if c == 0x0D {
                        starts.append(location + i + 1)
                        previousWasCR = true
                    } else {
                        previousWasCR = false
                    }
                }
            }
            location += count
        }
        self.starts = starts
    }

    var lineCount: Int { starts.count }

    /// 0-based line containing the UTF-16 offset `index`.
    func line(containing index: Int) -> Int {
        var lo = 0, hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= index { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    func start(ofLine line: Int) -> Int {
        if line < 0 { return 0 }
        if line >= starts.count { return length }
        return starts[line]
    }
}
