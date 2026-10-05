import Foundation

// Shared duplicate-key/depth preflight; JSONDecoder still validates complete JSON grammar.
func boundedJSON(_ data: Data) -> Bool {
    struct Frame {
        var object: Bool
        var expectsKey: Bool
        var keys: Set<String> = []
    }
    var stack: [Frame] = []
    var quoted = false
    var escaped = false
    var keyStart: Int?
    let bytes = Array(data)
    for (index, byte) in bytes.enumerated() {
        if quoted {
            if escaped {
                escaped = false
            } else if byte == 92 {
                escaped = true
            } else if byte == 34 {
                quoted = false
                if let start = keyStart {
                    guard
                        let key = try? JSONDecoder().decode(
                            String.self, from: Data(bytes[start...index])),
                        !stack.isEmpty, stack[stack.count - 1].keys.insert(key).inserted
                    else { return false }
                    keyStart = nil
                }
            }
        } else if byte == 34 {
            quoted = true
            if stack.last?.object == true, stack.last?.expectsKey == true { keyStart = index }
        } else if byte == 123 || byte == 91 {
            stack.append(Frame(object: byte == 123, expectsKey: byte == 123))
            if stack.count > 32 { return false }
        } else if byte == 125 || byte == 93 {
            guard let top = stack.popLast(), top.object == (byte == 125) else { return false }
        } else if byte == 58, !stack.isEmpty, stack.last?.object == true {
            stack[stack.count - 1].expectsKey = false
        } else if byte == 44, !stack.isEmpty, stack.last?.object == true {
            stack[stack.count - 1].expectsKey = true
        }
    }
    return stack.isEmpty && !quoted
}
