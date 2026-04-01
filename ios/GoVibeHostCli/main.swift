import Foundation

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "start"

let authConfig = CLIAuthConfig()
let controller = CLIHostController(authConfig: authConfig)

switch command {
case "start":
    var sessionName: String?
    var shellPath: String?
    var iterator = args.dropFirst().makeIterator()
    while let arg = iterator.next() {
        switch arg {
        case "--session-name":
            sessionName = iterator.next()
        case "--shell":
            shellPath = iterator.next()
        default:
            print("Unknown option: \(arg)")
            printUsage()
            exit(1)
        }
    }

    Task {
        do {
            try await controller.run(sessionName: sessionName, shellPath: shellPath)
        } catch {
            print("Error: \(error.localizedDescription)")
            exit(1)
        }
        exit(0)
    }
    RunLoop.main.run()

case "sign-out":
    controller.signOut()

case "--help", "-h", "help":
    printUsage()

default:
    print("Unknown command: \(command)")
    printUsage()
    exit(1)
}

func printUsage() {
    print("""
    Usage: govibe-host-cli <command> [options]

    Commands:
      start       Start the CLI host (default)
      sign-out    Remove saved credentials
      help        Show this help message

    Options for 'start':
      --session-name NAME   Terminal session name (default: "default")
      --shell PATH          Shell executable path (default: $SHELL or /bin/zsh)

    Environment variables:
      GOVIBE_GCP_PROJECT_ID              GCP project ID
      GOVIBE_GCP_REGION                  GCP region
      GOVIBE_GCP_RELAY_HOST              Relay server hostname
      GOVIBE_FIREBASE_API_KEY            Firebase Web API key
      GOVIBE_GOOGLE_DEVICE_CLIENT_ID     Google OAuth device flow client ID
      GOVIBE_GOOGLE_DEVICE_CLIENT_SECRET Google OAuth device flow client secret
    """)
}
