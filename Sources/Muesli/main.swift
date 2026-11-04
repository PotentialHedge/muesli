import Foundation

// One binary: a CLI when given a known command, otherwise the menu bar app.
let arguments = Array(CommandLine.arguments.dropFirst())
if let command = arguments.first, CLI.commands.contains(command) {
    exit(CLI.run(arguments))
}
MuesliApp.main()
