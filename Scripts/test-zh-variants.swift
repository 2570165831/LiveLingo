import Foundation

/// Foundation-only converter probe. Accepts synthetic/public text on stdin.
@main struct ChineseVariantProbe {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard args.count == 1, let mode = ChineseScriptConverter.Mode(rawValue: args[0]) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let converter = ChineseScriptConverter()
        let output = try converter.convert(input, mode: mode)
        FileHandle.standardOutput.write(Data(output.utf8))
    }
}
