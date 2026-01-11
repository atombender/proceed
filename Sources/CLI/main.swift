import Foundation

// MARK: - Configuration

let applicationSupportPath = FileManager.default
  .homeDirectoryForCurrentUser
  .appendingPathComponent("Library/Application Support/Proceed")

func loadSettings() -> GlobalSettings? {
  let settingsPath = applicationSupportPath.appendingPathComponent("settings.json")
  guard let data = try? Data(contentsOf: settingsPath),
    let settings = try? JSONDecoder().decode(GlobalSettings.self, from: data)
  else {
    return nil
  }
  return settings
}

func getBaseURL() -> String {
  // Check for --url flag first
  let args = CommandLine.arguments
  if let urlIndex = args.firstIndex(of: "--url"), urlIndex + 1 < args.count {
    return args[urlIndex + 1]
  }

  // Read port from settings
  let settings = loadSettings()
  let port = settings?.httpAPIPort ?? Constants.defaultHTTPPort
  return "http://localhost:\(port)"
}

// MARK: - HTTP Client

enum HTTPMethod: String {
  case get = "GET"
  case post = "POST"
  case patch = "PATCH"
}

func makeRequest(
  method: HTTPMethod,
  path: String,
  body: [String: Any]? = nil
) -> (statusCode: Int, data: Data?, error: String?) {
  let baseURL = getBaseURL()
  let fullURL = "\(baseURL)\(path)"

  // Use curl for HTTP requests - more reliable in CLI context
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")

  var args = ["-s", "-w", "\n%{http_code}", "-X", method.rawValue]
  args.append(contentsOf: ["-H", "Content-Type: application/json"])

  if let body = body, let bodyData = try? JSONSerialization.data(withJSONObject: body) {
    if let bodyString = String(data: bodyData, encoding: .utf8) {
      args.append(contentsOf: ["-d", bodyString])
    }
  }

  args.append(fullURL)
  process.arguments = args

  let outputPipe = Pipe()
  let errorPipe = Pipe()
  process.standardOutput = outputPipe
  process.standardError = errorPipe

  do {
    try process.run()
    process.waitUntilExit()
  } catch {
    return (0, nil, "Failed to run curl: \(error.localizedDescription)")
  }

  let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
  guard let output = String(data: outputData, encoding: .utf8) else {
    return (0, nil, "Invalid output from curl")
  }

  // Parse output: body + newline + status code (last line)
  // Find the last newline - everything after it is the status code
  if let lastNewlineRange = output.range(of: "\n", options: .backwards) {
    let statusCodeStr = String(output[lastNewlineRange.upperBound...])
    let statusCode = Int(statusCodeStr) ?? 0
    let bodyString = String(output[..<lastNewlineRange.lowerBound])
    return (statusCode, bodyString.data(using: .utf8), nil)
  }

  // No newline means just a status code (empty body)
  let statusCode = Int(output) ?? 0
  return (statusCode, nil, nil)
}

// MARK: - Commands

func printUsage() {
  let usage = """
    Usage: proceed <command> [options]

    Commands:
      start [flags] [--] <command>  Start a new process
      update [flags] <id>           Update process settings
      stop <id>                     Stop a process
      restart <id>                  Restart a process
      list                          List all processes

    Global Options:
      --url <url>                   Override the API URL

    Start Options:
      --id <id>                     Set a custom process ID
      --cwd <path>                  Set the working directory
      --name <name>                 Set the display name
      --auto-reload                 Enable auto-reload
      --include <pattern>           Add include pattern for auto-reload
      --exclude <pattern>           Add exclude pattern for auto-reload
      --shell <shell>               Override the shell

    Update Options:
      --name <name>                 Change display name
      --command <command>           Change command (causes restart)
      --cwd <path>                  Change working directory (causes restart)
      --auto-reload [true|false]    Enable/disable auto-reload

    Examples:
      proceed start -- npm run dev
      proceed start --name "Dev Server" --cwd ~/project -- npm run dev
      proceed stop abc123
      proceed list
    """
  print(usage)
}

func parseArgs(_ args: [String]) -> (
  flags: [String: String], positional: [String], arrays: [String: [String]]
) {
  var flags: [String: String] = [:]
  var positional: [String] = []
  var arrays: [String: [String]] = [:]
  var i = 0

  while i < args.count {
    let arg = args[i]

    // If we hit --, everything after is positional
    if arg == "--" {
      i += 1
      while i < args.count {
        positional.append(args[i])
        i += 1
      }
      break
    }

    if arg.hasPrefix("--") {
      let flagName = String(arg.dropFirst(2))

      // Boolean flags (no value)
      if flagName == "auto-reload" {
        // Check if next arg is true/false
        if i + 1 < args.count && (args[i + 1] == "true" || args[i + 1] == "false") {
          flags[flagName] = args[i + 1]
          i += 2
        } else {
          flags[flagName] = "true"
          i += 1
        }
        continue
      }

      // Array flags
      if flagName == "include" || flagName == "exclude" {
        if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
          if arrays[flagName] == nil {
            arrays[flagName] = []
          }
          arrays[flagName]?.append(args[i + 1])
          i += 2
        } else {
          i += 1
        }
        continue
      }

      // Regular flags with values
      if i + 1 < args.count && !args[i + 1].hasPrefix("--") {
        flags[flagName] = args[i + 1]
        i += 2
      } else {
        i += 1
      }
    } else {
      positional.append(arg)
      i += 1
    }
  }

  return (flags, positional, arrays)
}

func cmdStart(_ args: [String]) {
  let parsed = parseArgs(args)

  // positional[0] = executable path, positional[1] = "start", positional[2...] = command parts
  let commandParts: [String]
  if parsed.positional.count > 2 {
    commandParts = Array(parsed.positional.dropFirst(2))
  } else {
    fputs("Error: No command specified\n", stderr)
    exit(1)
  }

  let command = commandParts.joined(separator: " ")

  var body: [String: Any] = ["command": command]

  if let id = parsed.flags["id"] {
    body["id"] = id
  }
  if let cwd = parsed.flags["cwd"] {
    body["workingDirectory"] = cwd
  }
  if let name = parsed.flags["name"] {
    body["name"] = name
  }
  if let shell = parsed.flags["shell"] {
    body["shell"] = shell
  }
  if parsed.flags["auto-reload"] == "true" {
    body["autoReload"] = true
  }
  if let includes = parsed.arrays["include"], !includes.isEmpty {
    body["autoReloadIncludes"] = includes
  }
  if let excludes = parsed.arrays["exclude"], !excludes.isEmpty {
    body["autoReloadExcludes"] = excludes
  }

  let result = makeRequest(method: .post, path: "/processes", body: body)

  if let error = result.error {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  }

  if result.statusCode == 201, let data = result.data,
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let id = json["id"] as? String
  {
    print(id)
  } else if let data = result.data,
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let error = json["error"] as? String
  {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  } else {
    fputs("Error: Failed to start process (HTTP \(result.statusCode))\n", stderr)
    exit(1)
  }
}

func cmdUpdate(_ args: [String]) {
  let parsed = parseArgs(args)

  // positional[0] = executable path, positional[1] = "update", positional[2] = process ID
  guard parsed.positional.count >= 3 else {
    fputs("Error: Process ID required\n", stderr)
    exit(1)
  }

  let processId = parsed.positional[2]
  var body: [String: Any] = [:]

  if let name = parsed.flags["name"] {
    body["name"] = name
  }
  if let command = parsed.flags["command"] {
    body["command"] = command
  }
  if let cwd = parsed.flags["cwd"] {
    body["workingDirectory"] = cwd
  }
  if let autoReload = parsed.flags["auto-reload"] {
    body["autoReload"] = autoReload == "true"
  }

  if body.isEmpty {
    fputs("Error: No updates specified\n", stderr)
    exit(1)
  }

  let result = makeRequest(method: .patch, path: "/processes/\(processId)", body: body)

  if let error = result.error {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  }

  if result.statusCode == 200 {
    print("Updated")
  } else if result.statusCode == 404 {
    fputs("Error: Process not found\n", stderr)
    exit(1)
  } else if let data = result.data,
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let error = json["error"] as? String
  {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  } else {
    fputs("Error: Failed to update process (HTTP \(result.statusCode))\n", stderr)
    exit(1)
  }
}

func cmdStop(_ args: [String]) {
  guard args.count >= 3 else {
    fputs("Error: Process ID required\n", stderr)
    exit(1)
  }

  let processId = args[2]
  let result = makeRequest(method: .post, path: "/processes/\(processId)/stop")

  if let error = result.error {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  }

  if result.statusCode == 200 {
    print("Stopped")
  } else if result.statusCode == 404 {
    fputs("Error: Process not found\n", stderr)
    exit(1)
  } else {
    fputs("Error: Failed to stop process (HTTP \(result.statusCode))\n", stderr)
    exit(1)
  }
}

func cmdRestart(_ args: [String]) {
  guard args.count >= 3 else {
    fputs("Error: Process ID required\n", stderr)
    exit(1)
  }

  let processId = args[2]
  let result = makeRequest(method: .post, path: "/processes/\(processId)/restart")

  if let error = result.error {
    fputs("Error: \(error)\n", stderr)
    exit(1)
  }

  if result.statusCode == 200 {
    print("Restarted")
  } else if result.statusCode == 404 {
    fputs("Error: Process not found\n", stderr)
    exit(1)
  } else {
    fputs("Error: Failed to restart process (HTTP \(result.statusCode))\n", stderr)
    exit(1)
  }
}

func cmdList(_ args: [String]) {
  let result = makeRequest(method: .get, path: "/processes")

  if let error = result.error {
    fputs("Error: \(error)\n", stderr)
    fputs("Is Proceed running with the HTTP API enabled?\n", stderr)
    exit(1)
  }

  guard result.statusCode == 200, let data = result.data,
    let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
    let processes = json["processes"] as? [[String: Any]]
  else {
    fputs("Error: Failed to list processes (HTTP \(result.statusCode))\n", stderr)
    exit(1)
  }

  if processes.isEmpty {
    print("No processes")
    return
  }

  // Print header
  print("ID                                    NAME                  STATUS      COMMAND")
  print(String(repeating: "-", count: 100))

  for process in processes {
    let id = process["id"] as? String ?? "?"
    let title = process["title"] as? String ?? "?"
    let status = process["status"] as? String ?? "?"
    let command = process["command"] as? String ?? ""

    // Truncate and pad values
    let paddedId = id.padding(toLength: 36, withPad: " ", startingAt: 0)
    let truncatedTitle = title.count > 20 ? String(title.prefix(17)) + "..." : title
    let paddedTitle = truncatedTitle.padding(toLength: 20, withPad: " ", startingAt: 0)
    let paddedStatus = status.padding(toLength: 10, withPad: " ", startingAt: 0)
    let truncatedCommand = command.count > 40 ? String(command.prefix(37)) + "..." : command

    print("\(paddedId)  \(paddedTitle)  \(paddedStatus)  \(truncatedCommand)")
  }
}

// MARK: - Main

func main() {
  // Filter out --url flag and its value for command processing
  var args = CommandLine.arguments
  if let urlIndex = args.firstIndex(of: "--url"), urlIndex + 1 < args.count {
    args.remove(at: urlIndex + 1)
    args.remove(at: urlIndex)
  }

  guard args.count >= 2 else {
    printUsage()
    exit(0)
  }

  let command = args[1]

  switch command {
  case "start":
    cmdStart(args)
  case "update":
    cmdUpdate(args)
  case "stop":
    cmdStop(args)
  case "restart":
    cmdRestart(args)
  case "list":
    cmdList(args)
  case "-h", "--help", "help":
    printUsage()
  default:
    fputs("Unknown command: \(command)\n", stderr)
    printUsage()
    exit(1)
  }
}

main()
