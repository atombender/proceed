import Foundation
import Network
import os.log

/// HTTP Server for the REST API
/// Listens on localhost on a configurable port
class HTTPServer: ObservableObject {
  static let shared = HTTPServer()

  @Published private(set) var isRunning = false
  @Published private(set) var port: UInt16 = 0
  @Published private(set) var url: String?

  private var listener: NWListener?
  private var connections: [NWConnection] = []
  private let queue = DispatchQueue(label: "com.proceed.httpserver", qos: .userInitiated)

  private init() {}

  /// Start the HTTP server on the configured port
  func start() {
    let configuredPort = SettingsManager.shared.httpAPIPort
    os_log(
      "start() called, isRunning=%{public}@, configuredPort=%{public}d", log: Logger.httpServer,
      type: .debug, isRunning ? "true" : "false", configuredPort)
    guard !isRunning else { return }

    do {
      let parameters = NWParameters.tcp
      parameters.allowLocalEndpointReuse = true

      // Use the configured port
      guard let nwPort = NWEndpoint.Port(rawValue: configuredPort) else {
        os_log(
          "Invalid port number: %{public}d", log: Logger.httpServer, type: .error, configuredPort)
        return
      }
      listener = try NWListener(using: parameters, on: nwPort)
      listener?.stateUpdateHandler = { [weak self] state in
        DispatchQueue.main.async {
          self?.handleStateUpdate(state)
        }
      }
      listener?.newConnectionHandler = { [weak self] connection in
        self?.handleNewConnection(connection)
      }

      listener?.start(queue: queue)
    } catch {
      os_log(
        "Failed to create listener: %{public}@", log: Logger.httpServer, type: .error,
        error.localizedDescription)
    }
  }

  /// Stop the HTTP server
  func stop() {
    listener?.cancel()
    listener = nil

    for connection in connections {
      connection.cancel()
    }
    connections.removeAll()

    DispatchQueue.main.async {
      self.isRunning = false
      self.port = 0
      self.url = nil
    }
  }

  private func handleStateUpdate(_ state: NWListener.State) {
    switch state {
    case .ready:
      if let port = listener?.port?.rawValue {
        self.port = port
        self.url = "http://localhost:\(port)"
        self.isRunning = true
        os_log(
          "Listening on http://localhost:%{public}d", log: Logger.httpServer, type: .info, port)
      }
    case .failed(let error):
      os_log(
        "Listener failed: %{public}@", log: Logger.httpServer, type: .error,
        error.localizedDescription)
      isRunning = false
    case .cancelled:
      isRunning = false
    default:
      break
    }
  }

  private func handleNewConnection(_ connection: NWConnection) {
    connections.append(connection)

    connection.stateUpdateHandler = { [weak self, weak connection] state in
      if case .cancelled = state, let conn = connection {
        self?.connections.removeAll { $0 === conn }
      }
    }

    receiveRequest(on: connection)
    connection.start(queue: queue)
  }

  private func receiveRequest(on connection: NWConnection) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
      [weak self] data, _, isComplete, error in
      if let data = data, !data.isEmpty {
        self?.handleRequest(data: data, connection: connection)
      }
      if isComplete || error != nil {
        connection.cancel()
      }
    }
  }

  // MARK: - HTTP Request Handling

  private func handleRequest(data: Data, connection: NWConnection) {
    guard let request = String(data: data, encoding: .utf8) else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
      return
    }

    // Parse HTTP request
    let lines = request.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid request"])
      return
    }

    let parts = requestLine.components(separatedBy: " ")
    guard parts.count >= 2 else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid request line"])
      return
    }

    let method = parts[0]
    let path = parts[1]

    // Find the body (after empty line)
    var body: Data?
    if let emptyLineIndex = lines.firstIndex(of: "") {
      let bodyLines = lines[(emptyLineIndex + 1)...]
      let bodyString = bodyLines.joined(separator: "\r\n")
      body = bodyString.data(using: .utf8)
    }

    // Route the request
    routeRequest(method: method, path: path, body: body, connection: connection)
  }

  private func routeRequest(method: String, path: String, body: Data?, connection: NWConnection) {
    // Parse path and extract ID if present
    let pathComponents = path.split(separator: "/").map(String.init)

    // Route based on method and path
    if method == "GET" && pathComponents == ["processes"] {
      handleListProcesses(connection: connection)
    } else if method == "POST" && pathComponents == ["processes"] {
      handleStartProcess(body: body, connection: connection)
    } else if method == "PATCH" && pathComponents.count == 2 && pathComponents[0] == "processes" {
      handleUpdateProcess(id: pathComponents[1], body: body, connection: connection)
    } else if method == "POST" && pathComponents.count == 3 && pathComponents[0] == "processes"
      && pathComponents[2] == "stop"
    {
      handleStopProcess(id: pathComponents[1], connection: connection)
    } else if method == "POST" && pathComponents.count == 3 && pathComponents[0] == "processes"
      && pathComponents[2] == "restart"
    {
      handleRestartProcess(id: pathComponents[1], connection: connection)
    } else {
      sendResponse(connection: connection, status: 404, body: ["error": "Not found"])
    }
  }

  // MARK: - API Handlers

  private func handleListProcesses(connection: NWConnection) {
    DispatchQueue.main.async { [weak self] in
      // Get all panels from all windows
      let allPanels = WindowManager.shared.allPanels()

      var processList: [[String: Any]] = []
      for panel in allPanels {
        var processInfo: [String: Any] = [
          "id": panel.id.uuidString,
          "title": panel.title,
          "status": panel.status.apiString,
        ]
        if let config = panel.processConfig {
          processInfo["command"] = config.command
          processInfo["workingDirectory"] = config.workingDirectory
          processInfo["shell"] = config.shell
        }
        processList.append(processInfo)
      }

      self?.sendResponse(connection: connection, status: 200, body: ["processes": processList])
    }
  }

  private func handleStartProcess(body: Data?, connection: NWConnection) {
    guard let body = body,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid JSON body"])
      return
    }

    guard let command = json["command"] as? String else {
      sendResponse(
        connection: connection, status: 400, body: ["error": "Missing required field: command"])
      return
    }

    let name = json["name"] as? String ?? command.components(separatedBy: " ").first ?? "Process"
    let workingDirectory =
      json["workingDirectory"] as? String ?? FileManager.default.currentDirectoryPath
    let shell = json["shell"] as? String ?? "/bin/zsh"
    let customId = json["id"] as? String

    // Parse optional auto-reload settings
    let autoReload = json["autoReload"] as? Bool ?? false
    let autoReloadIncludes = json["autoReloadIncludes"] as? [String] ?? []
    let autoReloadExcludes = json["autoReloadExcludes"] as? [String] ?? []

    DispatchQueue.main.async { [weak self] in
      guard let tilingState = WindowManager.shared.firstTilingState() else {
        self?.sendResponse(
          connection: connection, status: 500, body: ["error": "No window available"])
        return
      }

      // Check for duplicate custom ID across all windows
      if let customId = customId {
        if let existingId = UUID(uuidString: customId),
          WindowManager.shared.findPanel(id: existingId) != nil
        {
          self?.sendResponse(
            connection: connection, status: 409, body: ["error": "Process with ID already exists"])
          return
        }
      }

      let config = ProcessConfig(
        id: customId.flatMap { UUID(uuidString: $0) } ?? UUID(),
        name: name,
        command: command,
        workingDirectory: workingDirectory,
        shell: shell,
        autoReloadEnabled: autoReload,
        autoReloadIncludes: autoReloadIncludes,
        autoReloadExcludes: autoReloadExcludes
      )

      tilingState.runProcess(config: config)

      // Find the panel that was just created
      if let panel = tilingState.panels.values.first(where: { $0.processConfig?.id == config.id }) {
        self?.sendResponse(
          connection: connection, status: 201,
          body: [
            "id": panel.id.uuidString,
            "title": panel.title,
            "status": panel.status.apiString,
          ])
      } else {
        self?.sendResponse(
          connection: connection, status: 500, body: ["error": "Failed to create process"])
      }
    }
  }

  private func handleUpdateProcess(id: String, body: Data?, connection: NWConnection) {
    guard let uuid = UUID(uuidString: id) else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid process ID"])
      return
    }

    guard let body = body,
      let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid JSON body"])
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let found = WindowManager.shared.findPanel(id: uuid),
        var config = found.panel.processConfig
      else {
        self?.sendResponse(
          connection: connection, status: 404, body: ["error": "Process not found"])
        return
      }

      let panel = found.panel
      let tilingState = found.source
      var needsRestart = false

      // Update name if provided
      if let name = json["name"] as? String {
        config = config.updating(name: name)
      }

      // Update command if provided (requires restart)
      if let command = json["command"] as? String, command != config.command {
        config = config.updating(command: command)
        needsRestart = true
      }

      // Update working directory if provided (requires restart)
      if let workingDirectory = json["workingDirectory"] as? String,
        workingDirectory != config.workingDirectory
      {
        config = config.updating(workingDirectory: workingDirectory)
        needsRestart = true
      }

      // Update auto-reload if provided
      if let autoReload = json["autoReload"] as? Bool {
        config = config.updating(autoReloadEnabled: autoReload)
      }

      tilingState.updateProcess(forPanelId: uuid, newConfig: config)

      if needsRestart && panel.status == .running {
        tilingState.restartProcess(forPanelId: uuid)
      }

      self?.sendResponse(
        connection: connection, status: 200,
        body: [
          "id": panel.id.uuidString,
          "title": panel.title,
          "status": panel.status.apiString,
        ])
    }
  }

  private func handleStopProcess(id: String, connection: NWConnection) {
    guard let uuid = UUID(uuidString: id) else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid process ID"])
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let found = WindowManager.shared.findPanel(id: uuid) else {
        self?.sendResponse(
          connection: connection, status: 404, body: ["error": "Process not found"])
        return
      }

      let panel = found.panel
      let tilingState = found.source
      tilingState.stopProcess(forPanelId: uuid)

      self?.sendResponse(
        connection: connection, status: 200,
        body: [
          "id": panel.id.uuidString,
          "status": "stopped",
        ])
    }
  }

  private func handleRestartProcess(id: String, connection: NWConnection) {
    guard let uuid = UUID(uuidString: id) else {
      sendResponse(connection: connection, status: 400, body: ["error": "Invalid process ID"])
      return
    }

    DispatchQueue.main.async { [weak self] in
      guard let found = WindowManager.shared.findPanel(id: uuid) else {
        self?.sendResponse(
          connection: connection, status: 404, body: ["error": "Process not found"])
        return
      }

      let panel = found.panel
      let tilingState = found.source
      tilingState.restartProcess(forPanelId: uuid)

      self?.sendResponse(
        connection: connection, status: 200,
        body: [
          "id": panel.id.uuidString,
          "status": "running",
        ])
    }
  }

  // MARK: - Helpers

  private func sendResponse(connection: NWConnection, status: Int, body: [String: Any]) {
    let statusText: String
    switch status {
    case 200: statusText = "OK"
    case 201: statusText = "Created"
    case 400: statusText = "Bad Request"
    case 404: statusText = "Not Found"
    case 409: statusText = "Conflict"
    case 500: statusText = "Internal Server Error"
    default: statusText = "Unknown"
    }

    var jsonData = Data()
    if let data = try? JSONSerialization.data(
      withJSONObject: body, options: [.prettyPrinted, .sortedKeys])
    {
      jsonData = data
    }

    let response = """
      HTTP/1.1 \(status) \(statusText)\r
      Content-Type: application/json\r
      Content-Length: \(jsonData.count)\r
      Connection: close\r
      \r

      """

    var responseData = response.data(using: .utf8) ?? Data()
    responseData.append(jsonData)

    connection.send(
      content: responseData,
      completion: .contentProcessed { _ in
        connection.cancel()
      })
  }
}

// MARK: - ProcessStatus Extension

extension ProcessStatus {
  var apiString: String {
    switch self {
    case .running:
      return "running"
    case .exitedNormally:
      return "stopped"
    case .exitedWithError(let code):
      return "error:\(code)"
    case .restarting:
      return "restarting"
    }
  }
}
