import Foundation

/// Image bounds for diagnostics; reading headers neither hashes nor modifies the executable.
public enum PEImage {
    public static func addressRange(of executable: URL) -> Range<UInt64>? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let dos = try? handle.read(upToCount: 64), dos.count == 64, dos[0] == 0x4d, dos[1] == 0x5a else { return nil }
        func integer(_ data: Data, _ offset: Int, _ count: Int) -> UInt64 {
            data[offset..<(offset + count)].enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        let peOffset = integer(dos, 60, 4)
        guard peOffset >= 64, peOffset <= 1_048_576 else { return nil }
        do { try handle.seek(toOffset: peOffset) } catch { return nil }
        guard let pe = try? handle.read(upToCount: 88), pe.count == 88,
              Array(pe.prefix(4)) == [0x50, 0x45, 0, 0] else { return nil }
        let magic = integer(pe, 24, 2)
        guard magic == 0x20b || magic == 0x10b else { return nil }
        let base = magic == 0x20b ? integer(pe, 48, 8) : integer(pe, 52, 4)
        let size = integer(pe, 80, 4)
        guard size > 0, base <= UInt64.max - size else { return nil }
        return base..<(base + size)
    }
}
