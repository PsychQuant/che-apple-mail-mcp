import Foundation

/// Foundation validates JSON syntax but collapses duplicate object members.
/// Check the original wire spelling before consumers can use that dictionary.
/// Member names are decoded so escaped aliases such as "\u0069ds" also collide.
func decodeUniqueMemberJSON(_ data: Data) -> Any? {
    // The wire is UTF-8. Literal NUL is invalid JSON text and also catches
    // BOM-less UTF-16/32 that Foundation would otherwise auto-detect, while
    // this scanner reads UTF-8 bytes. Escaped \u0000 remains ordinary text.
    guard !data.contains(0), String(data: data, encoding: .utf8) != nil else { return nil }
    guard let value = try? JSONSerialization.jsonObject(with: data) else { return nil }
    let bytes = Array(data)
    var objects: [Set<String>] = []
    var index = 0
    while index < bytes.count {
        switch bytes[index] {
        case 0x7b: // {
            objects.append([])
            index += 1
        case 0x7d: // }
            guard !objects.isEmpty else { return nil }
            objects.removeLast()
            index += 1
        case 0x22: // A string token; structural bytes inside it are data.
            let start = index
            index += 1
            while index < bytes.count && bytes[index] != 0x22 {
                index += bytes[index] == 0x5c ? 2 : 1
            }
            guard index < bytes.count else { return nil }
            index += 1
            var next = index
            while next < bytes.count && [0x09, 0x0a, 0x0d, 0x20].contains(bytes[next]) { next += 1 }
            // With syntax already validated, only an object member name can
            // be a string immediately followed by a colon.
            if next < bytes.count && bytes[next] == 0x3a {
                guard !objects.isEmpty,
                      let name = try? JSONSerialization.jsonObject(
                        with: Data(bytes[start..<index]), options: .fragmentsAllowed) as? String,
                      objects[objects.count - 1].insert(name).inserted else { return nil }
            }
        default:
            index += 1
        }
    }
    return objects.isEmpty ? value : nil
}
