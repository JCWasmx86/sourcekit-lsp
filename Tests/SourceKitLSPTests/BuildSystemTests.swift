//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2020 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//

import BuildServerProtocol
import LSPTestSupport
import LanguageServerProtocol
import SKCore
import SKTestSupport
import SourceKitLSP
import TSCBasic
import XCTest

fileprivate extension SourceKitServer {
  func setWorkspaces(_ workspaces: [Workspace]) {
    self._workspaces = workspaces
  }
}

// Workaround ambiguity with Foundation.
typealias LSPNotification = LanguageServerProtocol.Notification

/// Build system to be used for testing BuildSystem and BuildSystemDelegate functionality with SourceKitServer
/// and other components.
final class TestBuildSystem: BuildSystem {
  var indexStorePath: AbsolutePath? = nil
  var indexDatabasePath: AbsolutePath? = nil
  var indexPrefixMappings: [PathPrefixMapping] = []

  weak var delegate: BuildSystemDelegate?

  public func setDelegate(_ delegate: BuildSystemDelegate?) async {
    self.delegate = delegate
  }

  /// Build settings by file.
  var buildSettingsByFile: [DocumentURI: FileBuildSettings] = [:]

  /// Files currently being watched by our delegate.
  var watchedFiles: Set<DocumentURI> = []

  func buildSettings(for document: DocumentURI, language: Language) async throws -> FileBuildSettings? {
    return buildSettingsByFile[document]
  }

  func registerForChangeNotifications(for uri: DocumentURI, language: Language) async {
    watchedFiles.insert(uri)
  }

  func unregisterForChangeNotifications(for uri: DocumentURI) {
    watchedFiles.remove(uri)
  }

  func filesDidChange(_ events: [FileEvent]) {}

  public func fileHandlingCapability(for uri: DocumentURI) -> FileHandlingCapability {
    if buildSettingsByFile[uri] != nil {
      return .handled
    } else {
      return .unhandled
    }
  }
}

final class BuildSystemTests: XCTestCase {

  /// Connection and lifetime management for the service.
  var testServer: TestSourceKitServer! = nil

  /// The server's workspace data. Accessing this is unsafe if the server does so concurrently.
  var workspace: Workspace! = nil

  /// The build system that we use to verify SourceKitServer behavior.
  var buildSystem: TestBuildSystem! = nil

  /// Whether clangd exists in the toolchain.
  var haveClangd: Bool = false

  override func setUp() {
    awaitTask(description: "Setup complete") {
      haveClangd = ToolchainRegistry.shared.toolchains.contains { $0.clangd != nil }
      testServer = TestSourceKitServer()
      buildSystem = TestBuildSystem()

      let server = testServer.server

      self.workspace = await Workspace(
        documentManager: DocumentManager(),
        rootUri: nil,
        capabilityRegistry: CapabilityRegistry(clientCapabilities: ClientCapabilities()),
        toolchainRegistry: ToolchainRegistry.shared,
        buildSetup: TestSourceKitServer.serverOptions.buildSetup,
        underlyingBuildSystem: buildSystem,
        index: nil,
        indexDelegate: nil
      )

      await server.setWorkspaces([workspace])
      await workspace.buildSystemManager.setDelegate(server)

      _ = try await testServer.send(
        InitializeRequest(
          processId: nil,
          rootPath: nil,
          rootURI: nil,
          initializationOptions: nil,
          capabilities: ClientCapabilities(workspace: nil, textDocument: nil),
          trace: .off,
          workspaceFolders: nil
        )
      )
    }
  }

  override func tearDown() {
    buildSystem = nil
    workspace = nil
    testServer = nil
  }

  func testClangdDocumentUpdatedBuildSettings() async throws {
    try XCTSkipIf(true, "rdar://115435598 - crashing on rebranch")

    guard haveClangd else { return }

    #if os(Windows)
    let url = URL(fileURLWithPath: "C:/\(UUID())/file.m")
    #else
    let url = URL(fileURLWithPath: "/\(UUID())/file.m")
    #endif
    let doc = DocumentURI(url)
    let args = [url.path, "-DDEBUG"]
    let text = """
      #ifdef FOO
      static void foo() {}
      #endif

      int main() {
        foo();
        return 0;
      }
      """

    buildSystem.buildSettingsByFile[doc] = FileBuildSettings(compilerArguments: args)

    let documentManager = await self.testServer.server._documentManager

    testServer.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: doc,
          language: .objective_c,
          version: 12,
          text: text
        )
      )
    )
    let diags = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(diags.diagnostics.count, 1)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)

    // Modify the build settings and inform the delegate.
    // This should trigger a new publish diagnostics and we should no longer have errors.
    let newSettings = FileBuildSettings(compilerArguments: args + ["-DFOO"])
    buildSystem.buildSettingsByFile[doc] = newSettings

    let expectation = XCTestExpectation(description: "refresh")
    let refreshedDiags = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(refreshedDiags.diagnostics.count, 0)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)

    await buildSystem.delegate?.fileBuildSettingsChanged([doc])

    try await fulfillmentOfOrThrow([expectation])
  }

  func testSwiftDocumentUpdatedBuildSettings() async throws {
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let doc = DocumentURI(url)
    let args = FallbackBuildSystem(buildSetup: .default).buildSettings(for: doc, language: .swift)!.compilerArguments

    buildSystem.buildSettingsByFile[doc] = FileBuildSettings(compilerArguments: args)

    let text = """
      #if FOO
      func foo() {}
      #endif

      foo()
      """

    let documentManager = await self.testServer.server._documentManager

    testServer.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: doc,
          language: .swift,
          version: 12,
          text: text
        )
      )
    )
    let syntacticDiags1 = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(syntacticDiags1.diagnostics.count, 0)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)

    let semanticDiags1 = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(semanticDiags1.diagnostics.count, 1)

    // Modify the build settings and inform the delegate.
    // This should trigger a new publish diagnostics and we should no longer have errors.
    let newSettings = FileBuildSettings(compilerArguments: args + ["-DFOO"])
    buildSystem.buildSettingsByFile[doc] = newSettings

    await buildSystem.delegate?.fileBuildSettingsChanged([doc])

    let syntacticDiags2 = try await testServer.nextDiagnosticsNotification()
    // Semantic analysis - SourceKit currently caches diagnostics so we still see an error.
    XCTAssertEqual(syntacticDiags2.diagnostics.count, 1)

    let semanticDiags2 = try await testServer.nextDiagnosticsNotification()
    // Semantic analysis - no expected errors here because we fixed the settings.
    XCTAssertEqual(semanticDiags2.diagnostics.count, 0)
  }

  func testClangdDocumentFallbackWithholdsDiagnostics() async throws {
    try XCTSkipIf(!haveClangd)

    #if os(Windows)
    let url = URL(fileURLWithPath: "C:/\(UUID())/file.m")
    #else
    let url = URL(fileURLWithPath: "/\(UUID())/file.m")
    #endif
    let doc = DocumentURI(url)
    let args = [url.path, "-DDEBUG"]
    let text = """
        #ifdef FOO
        static void foo() {}
        #endif

        int main() {
          foo();
          return 0;
        }
      """

    let documentManager = await self.testServer.server._documentManager

    testServer.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: doc,
          language: .objective_c,
          version: 12,
          text: text
        )
      )
    )
    let openDiags = try await testServer.nextDiagnosticsNotification()
    // Expect diagnostics to be withheld.
    XCTAssertEqual(openDiags.diagnostics.count, 0)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)

    // Modify the build settings and inform the delegate.
    // This should trigger a new publish diagnostics and we should see a diagnostic.
    let newSettings = FileBuildSettings(compilerArguments: args)
    buildSystem.buildSettingsByFile[doc] = newSettings

    await buildSystem.delegate?.fileBuildSettingsChanged([doc])

    let refreshedDiags = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(refreshedDiags.diagnostics.count, 1)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)
  }

  func testSwiftDocumentFallbackWithholdsSemanticDiagnostics() async throws {
    let url = URL(fileURLWithPath: "/\(UUID())/a.swift")
    let doc = DocumentURI(url)

    // Primary settings must be different than the fallback settings.
    var primarySettings = FallbackBuildSystem(buildSetup: .default).buildSettings(for: doc, language: .swift)!
    primarySettings.compilerArguments.append("-DPRIMARY")

    let text = """
        #if FOO
        func foo() {}
        #endif

        foo()
        func
      """

    let documentManager = await self.testServer.server._documentManager

    testServer.send(
      DidOpenTextDocumentNotification(
        textDocument: TextDocumentItem(
          uri: doc,
          language: .swift,
          version: 12,
          text: text
        )
      )
    )
    let openSyntacticDiags = try await testServer.nextDiagnosticsNotification()
    // Syntactic analysis - one expected errors here (for `func`).
    XCTAssertEqual(openSyntacticDiags.diagnostics.count, 1)
    XCTAssertEqual(text, documentManager.latestSnapshot(doc)!.text)
    let openSemanticDiags = try await testServer.nextDiagnosticsNotification()
    // Should be the same syntactic analysis since we are using fallback arguments
    XCTAssertEqual(openSemanticDiags.diagnostics.count, 1)

    // Swap from fallback settings to primary build system settings.
    buildSystem.buildSettingsByFile[doc] = primarySettings

    await buildSystem.delegate?.fileBuildSettingsChanged([doc])

    let refreshedSyntacticDiags = try await testServer.nextDiagnosticsNotification()
    // Syntactic analysis with new args - one expected errors here (for `func`).
    XCTAssertEqual(refreshedSyntacticDiags.diagnostics.count, 1)

    let refreshedSemanticDiags = try await testServer.nextDiagnosticsNotification()
    // Semantic analysis - two errors since `-DFOO` was not passed.
    XCTAssertEqual(refreshedSemanticDiags.diagnostics.count, 2)
  }

  func testMainFilesChanged() async throws {
    try XCTSkipIf(true, "rdar://115176405 - failing on rebranch due to extra published diagnostic")

    let ws = try await mutableSourceKitTibsTestWorkspace(name: "MainFiles")!
    let unique_h = ws.testLoc("unique").docIdentifier.uri

    try ws.openDocument(unique_h.fileURL!, language: .cpp)

    let openSyntacticDiags = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(openSyntacticDiags.diagnostics.count, 0)

    try ws.buildAndIndex()
    let diagsFromD = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(diagsFromD.diagnostics.count, 1)
    let diagFromD = try XCTUnwrap(diagsFromD.diagnostics.first)
    XCTAssertEqual(diagFromD.severity, .warning)
    XCTAssertEqual(diagFromD.message, "UNIQUE_INCLUDED_FROM_D")

    try ws.edit(rebuild: true) { (changes, _) in
      changes.write(
        """
        // empty
        """,
        to: ws.testLoc("d_func").url
      )
      changes.write(
        """
        #include "unique.h"
        """,
        to: ws.testLoc("c_func").url
      )
    }

    let diagsFromC = try await testServer.nextDiagnosticsNotification()
    XCTAssertEqual(diagsFromC.diagnostics.count, 1)
    let diagFromC = try XCTUnwrap(diagsFromC.diagnostics.first)
    XCTAssertEqual(diagFromC.severity, .warning)
    XCTAssertEqual(diagFromC.message, "UNIQUE_INCLUDED_FROM_C")
  }

  private func clangBuildSettings(for uri: DocumentURI) -> FileBuildSettings {
    return FileBuildSettings(compilerArguments: [uri.pseudoPath, "-DDEBUG"])
  }
}
