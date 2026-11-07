import Foundation
import CanoeCore

@main
struct CanoeCLI {
    static func main() {
        let code = runCLI(Array(CommandLine.arguments.dropFirst()))
        exit(code)
    }
}
