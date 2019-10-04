import TSCBasic
import TSCUtility

/// How should the Swift module output be handled?
public enum ModuleOutput: Equatable {
  /// The Swift module is a top-level output.
  case topLevel(VirtualPath)

  /// The Swift module is an auxiliary output.
  case auxiliary(VirtualPath)

  public var outputPath: VirtualPath {
    switch self {
    case .topLevel(let path):
      return path

    case .auxiliary(let path):
      return path
    }
  }
}

/// The Swift driver.
public struct Driver {
  enum Error: Swift.Error {
    case invalidDriverName(String)
    case invalidInput(String)
  }

  /// Diagnostic engine for emitting warnings, errors, etc.
  public let diagnosticEngine: DiagnosticsEngine

  /// The target triple.
  public let targetTriple: Triple

  /// The toolchain to use for resolution.
  public let toolchain: Toolchain

  /// The kind of driver.
  public let driverKind: DriverKind

  /// The option table we're using.
  let optionTable: OptionTable

  /// The set of parsed options.
  var parsedOptions: ParsedOptions

  /// The Swift compiler executable.
  public let swiftCompiler: VirtualPath

  /// Extra command-line arguments to pass to the Swift compiler.
  public let swiftCompilerPrefixArgs: [String]

  /// The working directory for the driver, if there is one.
  public let workingDirectory: AbsolutePath?

  /// The set of input files
  public let inputFiles: [TypedVirtualPath]

  /// The mapping from input files to output files for each kind.
  internal let outputFileMap: OutputFileMap?

  /// The mode in which the compiler will execute.
  public let compilerMode: CompilerMode

  /// Whether to print out incremental build decisions
  public let showIncrementalBuildDecisions: Bool

  /// Is the build incremental?
  public let isIncremental: Bool

  /// The type of the primary output generated by the compiler.
  public let compilerOutputType: FileType?

  /// The type of the primary output generated by the linker.
  public let linkerOutputType: LinkOutputType?

  /// When > 0, the number of threads to use in a multithreaded build.
  public let numThreads: Int

  /// The level of debug information to produce.
  public let debugInfoLevel: DebugInfoLevel?

  /// The debug info format to use.
  public let debugInfoFormat: DebugInfoFormat

  /// The form that the module output will take, e.g., top-level vs. auxiliary, and the path at which the module should be emitted.
  /// \c nil if no module should be emitted.
  public let moduleOutput: ModuleOutput?

  /// The name of the Swift module being built.
  public let moduleName: String

  /// The path of the SDK.
  public let sdkPath: String?

  /// The path to the imported Objective-C header.
  public let importedObjCHeader: VirtualPath?

  /// Path to the dependencies file.
  public let dependenciesFilePath: VirtualPath?

  /// Path to the reference dependencies (.swiftdeps) file.
  public let referenceDependenciesFilePath: VirtualPath?

  /// Path to the serialized diagnostics file.
  public let serializedDiagnosticsFilePath: VirtualPath?

  /// Path to the Objective-C generated header.
  public let objcGeneratedHeaderPath: VirtualPath?

  /// Path to the loaded module trace file.
  public let loadedModuleTracePath: VirtualPath?

  /// Path to the TBD file (text-based dylib).
  public let tbdPath: VirtualPath?

  /// Path to the module documentation file.
  public let moduleDocOutputPath: VirtualPath?

  /// Path to the Swift interface file.
  public let swiftInterfacePath: VirtualPath?

  /// Path to the optimization record.
  public let optimizationRecordPath: VirtualPath?

  /// Handler for emitting diagnostics to stderr.
  public static let stderrDiagnosticsHandler: DiagnosticsEngine.DiagnosticsHandler = { diagnostic in
    let stream = stderrStream
    if !(diagnostic.location is UnknownLocation) {
        stream <<< diagnostic.location.description <<< ": "
    }

    switch diagnostic.message.behavior {
    case .error:
      stream <<< "error: "
    case .warning:
      stream <<< "warning: "
    case .note:
      stream <<< "note: "
    case .ignored:
        break
    }

    stream <<< diagnostic.localizedDescription <<< "\n"
    stream.flush()
  }

  /// Create the driver with the given arguments.
  public init(
    args: [String],
    diagnosticsHandler: @escaping DiagnosticsEngine.DiagnosticsHandler = Driver.stderrDiagnosticsHandler
  ) throws {
    // FIXME: Determine if we should run as subcommand.

    let args = try Self.expandResponseFiles(args)
    self.diagnosticEngine = DiagnosticsEngine(handlers: [diagnosticsHandler])
    self.driverKind = try Self.determineDriverKind(args: args)
    self.optionTable = OptionTable()
    self.parsedOptions = try optionTable.parse(Array(args.dropFirst()))

    if let targetTriple = self.parsedOptions.getLastArgument(.target)?.asSingle {
      self.targetTriple = Triple(targetTriple)
    } else {
      self.targetTriple = try Triple.hostTargetTriple.get()
    }
    self.toolchain = try Self.computeToolchain(self.targetTriple, diagnosticsEngine: diagnosticEngine)

    // Find the Swift compiler executable.
    if let frontendPath = self.parsedOptions.getLastArgument(.driver_use_frontend_path) {
      let frontendCommandLine = frontendPath.asSingle.split(separator: ";").map { String($0) }
      if frontendCommandLine.isEmpty {
        self.diagnosticEngine.emit(.error_no_swift_frontend)
        self.swiftCompiler = .absolute(try self.toolchain.getToolPath(.swiftCompiler))
      } else {
        self.swiftCompiler = try VirtualPath(path: frontendCommandLine.first!)
      }
      self.swiftCompilerPrefixArgs = Array(frontendCommandLine.dropFirst())
    } else {
      self.swiftCompiler = .absolute(try self.toolchain.getToolPath(.swiftCompiler))
      self.swiftCompilerPrefixArgs = []
    }

    // Compute the working directory.
    workingDirectory = try parsedOptions.getLastArgument(.working_directory).map { workingDirectoryArg in
      let cwd = localFileSystem.currentWorkingDirectory
      return try cwd.map{ AbsolutePath(workingDirectoryArg.asSingle, relativeTo: $0) } ?? AbsolutePath(validating: workingDirectoryArg.asSingle)
    }

    // Apply the working directory to the parsed options.
    if let workingDirectory = self.workingDirectory {
      try Self.applyWorkingDirectory(workingDirectory, to: &self.parsedOptions)
    }

    // Classify and collect all of the input files.
    self.inputFiles = try Self.collectInputFiles(&self.parsedOptions)

    // Initialize an empty output file map, which will be populated when we start creating jobs.
    let outputFileMap: OutputFileMap?
    if let outputFileMapArg = parsedOptions.getLastArgument(.output_file_map)?.asSingle {
      let path = try AbsolutePath(validating: outputFileMapArg)
      outputFileMap = try .load(file: path, diagnosticEngine: diagnosticEngine)
    }
    else {
      outputFileMap = nil
    }
    self.outputFileMap = outputFileMap

    // Determine the compilation mode.
    self.compilerMode = Self.computeCompilerMode(&parsedOptions, driverKind: driverKind)

    // Determine whether the compilation should be incremental
    (showIncrementalBuildDecisions: self.showIncrementalBuildDecisions,
     shouldBeIncremental: self.isIncremental) =
        Self.computeIncrementalPredicates(&parsedOptions, driverKind: driverKind)

    // Figure out the primary outputs from the driver.
    (self.compilerOutputType, self.linkerOutputType) = Self.determinePrimaryOutputs(&parsedOptions, driverKind: driverKind, diagnosticsEngine: diagnosticEngine)

    // Multithreading.
    self.numThreads = Self.determineNumThreads(&parsedOptions, compilerMode: compilerMode, diagnosticsEngine: diagnosticEngine)

    // Compute debug information output.
    (self.debugInfoLevel, self.debugInfoFormat) = Self.computeDebugInfo(&parsedOptions, diagnosticsEngine: diagnosticEngine)

    // Determine the module we're building and whether/how the module file itself will be emitted.
    (self.moduleOutput, self.moduleName) = try Self.computeModuleInfo(
      &parsedOptions, compilerOutputType: compilerOutputType, compilerMode: compilerMode, linkerOutputType: linkerOutputType,
      debugInfoLevel: debugInfoLevel, diagnosticsEngine: diagnosticEngine)

    self.sdkPath = Self.computeSDKPath(&parsedOptions, compilerMode: compilerMode, toolchain: toolchain, diagnosticsEngine: diagnosticEngine)

    self.importedObjCHeader = try Self.computeImportedObjCHeader(&parsedOptions, compilerMode: compilerMode, diagnosticEngine: diagnosticEngine)

    // Supplemental outputs.
    self.dependenciesFilePath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .dependencies, isOutput: .emit_dependencies, outputPath: .emit_dependencies_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.referenceDependenciesFilePath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .swiftDeps, isOutput: .emit_reference_dependencies, outputPath: .emit_reference_dependencies_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.serializedDiagnosticsFilePath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .diagnostics, isOutput: .serialize_diagnostics, outputPath: .serialize_diagnostics_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    // FIXME: -fixits-output-path
    self.objcGeneratedHeaderPath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .objcHeader, isOutput: .emit_objc_header, outputPath: .emit_objc_header_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.loadedModuleTracePath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .moduleTrace, isOutput: .emit_loaded_module_trace, outputPath: .emit_loaded_module_trace_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.tbdPath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .tbd, isOutput: .emit_tbd, outputPath: .emit_tbd_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.moduleDocOutputPath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .swiftDocumentation, isOutput: .emit_module_doc, outputPath: .emit_module_doc_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.swiftInterfacePath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .swiftInterface, isOutput: .emit_module_interface, outputPath: .emit_module_interface_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
    self.optimizationRecordPath = try Self.computeSupplementaryOutputPath(&parsedOptions, type: .optimizationRecord, isOutput: .save_optimization_record, outputPath: .save_optimization_record_path, compilerOutputType: compilerOutputType, moduleName: moduleName)
  }

  /// Expand response files in the input arguments and return a new argument list.
  public static func expandResponseFiles(_ args: [String]) throws -> [String] {
    // FIXME: This is very very prelimary. Need to look at how Swift compiler expands response file.

    var result: [String] = []

    // Go through each arg and add arguments from response files.
    for arg in args {
      if arg.first == "@", let responseFile = try? AbsolutePath(validating: String(arg.dropFirst())) {
        let contents = try localFileSystem.readFileContents(responseFile).cString
        result += contents.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
      } else {
        result.append(arg)
      }
    }

    return result
  }

  /// Determine the driver kind based on the command-line arguments.
  public static func determineDriverKind(
    args: [String],
    cwd: AbsolutePath? = localFileSystem.currentWorkingDirectory
  ) throws -> DriverKind {
    // Get the basename of the driver executable.
    let execPath = try cwd.map{ AbsolutePath(args[0], relativeTo: $0) } ?? AbsolutePath(validating: args[0])
    var driverName = execPath.basename

    // Determine driver kind based on the first argument.
    if args.count > 1 {
      let driverModeOption = "--driver-mode="
      if args[1].starts(with: driverModeOption) {
        driverName = String(args[1].dropFirst(driverModeOption.count))
      } else if args[1] == "-frontend" {
        return .frontend
      } else if args[1] == "-modulewrap" {
        return .moduleWrap
      }
    }

    switch driverName {
    case "swift":
      return .interactive
    case "swiftc":
      return .batch
    case "swift-autolink-extract":
      return .autolinkExtract
    case "swift-indent":
      return .indent
    default:
      throw Error.invalidDriverName(driverName)
    }
  }

  /// Run the driver.
  public mutating func run(resolver: ArgsResolver, executorDelegate: JobExecutorDelegate? = nil) throws {
    // We just need to invoke the corresponding tool if the kind isn't Swift compiler.
    guard driverKind.isSwiftCompiler else {
      let swiftCompiler = try getSwiftCompilerPath()
      return try exec(path: swiftCompiler.pathString, args: ["swift"] + parsedOptions.commandLine)
    }

    if parsedOptions.contains(.help) || parsedOptions.contains(.help_hidden) {
      optionTable.printHelp(usage: driverKind.usage, title: driverKind.title, includeHidden: parsedOptions.contains(.help_hidden))
      return
    }

    // Plan the build.
    let jobs = try planBuild()
    if jobs.isEmpty { return }

    // If we're only supposed to print the jobs, do so now.
    if parsedOptions.contains(.driver_print_jobs) {
      for job in jobs {
        print(job)
      }
      return
    }

    // Create and use the tool execution delegate if one is not provided explicitly.
    let executorDelegate = executorDelegate ?? createToolExecutionDelegate()

    // Start up an executor and perform the build.
    let mainOutput = jobs.last!.outputs.first!
    let jobExecutor = JobExecutor(jobs: jobs, resolver: resolver, executorDelegate: executorDelegate)
    try jobExecutor.build(mainOutput)
  }

  /// Returns the path to the Swift binary.
  func getSwiftCompilerPath() throws -> AbsolutePath {
    // FIXME: This is very preliminary. Need to figure out how to get the actual Swift executable path.
    let path = try Process.checkNonZeroExit(
      arguments: ["xcrun", "-sdk", "macosx", "--find", "swift"]).spm_chomp()
    return AbsolutePath(path)
  }

  mutating func createToolExecutionDelegate() -> ToolExecutionDelegate {
    var mode: ToolExecutionDelegate.Mode = .regular

    // FIXME: Old driver does _something_ if both are passed. Not sure if we want to support that.
    if parsedOptions.contains(.parseable_output) {
      mode = .parsableOutput
    } else if parsedOptions.contains(.v) {
      mode = .verbose
    }

    return ToolExecutionDelegate(mode: mode)
  }
}

extension Diagnostic.Message {
  static var error_no_swift_frontend: Diagnostic.Message {
    .error("-driver-use-frontend-path requires a Swift compiler executable argument")
  }

  static var warning_cannot_multithread_batch_mode: Diagnostic.Message {
    .warning("ignoring -num-threads argument; cannot multithread batch mode")
  }
}

extension Driver {
  /// Compute the compiler mode based on the options.
  private static func computeCompilerMode(
    _ parsedOptions: inout ParsedOptions,
    driverKind: DriverKind
  ) -> CompilerMode {
    // Some output flags affect the compiler mode.
    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option {
      case .emit_pch, .emit_imported_modules, .index_file:
        return .singleCompile

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        return .repl

      default:
        // Output flag doesn't determine the compiler mode.
        break
      }
    }

    if driverKind == .interactive {
      return parsedOptions.hasAnyInput ? .immediate : .repl
    }

    let requiresSingleCompile = parsedOptions.contains(.whole_module_optimization)

    // FIXME: Handle -enable-batch-mode and -disable-batch-mode flags.

    if requiresSingleCompile {
      return .singleCompile
    }

    return .standardCompile
  }
}

extension Driver {
    /// Compute whether the compilation should be incremental
    private static func computeIncrementalPredicates(
        _ parsedOptions: inout ParsedOptions,
        driverKind: DriverKind) -> (showIncrementalBuildDecisions: Bool, shouldBeIncremental: Bool) {
        let showIncrementalBuildDecisions = parsedOptions.hasArgument(.driver_show_incremental))
        guard (parsedOptions.hasArgument(.incremental) else {
            return (showIncrementalBuildDecisions: showIncrementalBuildDecisions, shouldBeIncremental: false)
            }
        guard let reasonToDisable = parsedOptions.hasArgument(.whole_module_optimization)
            ? "is not compatible with whole module optimization."
            : parsedOptions.hasArgument(.embed_bitcode)
            ? "is not currently compatible with embedding LLVM IR bitcode."
            : nil
        else {
            return (showIncrementalBuildDecisions: showIncrementalBuildDecisions, shouldBeIncremental: true)
        }
        if (showIncrementalBuildDecisions) {
            stderrStream <<<"Incremental compilation has been disabled, because it \(reasonToDisable)\n"
            stderrStream.flush()
        }
        return (showIncrementalBuildDecisions: showIncrementalBuildDecisions, shouldBeIncremental: false)
    }
}

/// Input and output file handling.
extension Driver {
  /// Apply the given working directory to all paths in the parsed options.
  private static func applyWorkingDirectory(_ workingDirectory: AbsolutePath,
                                            to parsedOptions: inout ParsedOptions) throws {
    parsedOptions.forEachModifying { parsedOption in
      // Only translate options whose arguments are paths.
      if !parsedOption.option.attributes.contains(.argumentIsPath) { return }

      let translatedArgument: ParsedOption.Argument
      switch parsedOption.argument {
      case .none:
        return

      case .single(let arg):
        if arg == "-" {
          translatedArgument = parsedOption.argument
        } else {
          translatedArgument = .single(AbsolutePath(arg, relativeTo: workingDirectory).pathString)
        }

      case .multiple(let args):
        translatedArgument = .multiple(args.map { arg in
          AbsolutePath(arg, relativeTo: workingDirectory).pathString
        })
      }

      parsedOption = .init(option: parsedOption.option, argument: translatedArgument)
    }
  }

  /// Collect all of the input files from the parsed options, translating them into input files.
  private static func collectInputFiles(_ parsedOptions: inout ParsedOptions) throws -> [TypedVirtualPath] {
    return try parsedOptions.allInputs.map { input in
      // Standard input is assumed to be Swift code.
      if input == "-" {
        return TypedVirtualPath(file: .standardInput, type: .swift)
      }

      // Resolve the input file.
      let file: VirtualPath
      let fileExtension: String
      if let absolute = try? AbsolutePath(validating: input) {
        file = .absolute(absolute)
        fileExtension = absolute.extension ?? ""
      } else {
        let relative = try RelativePath(validating: input)
        fileExtension = relative.extension ?? ""
        file = .relative(relative)
      }

      // Determine the type of the input file based on its extension.
      // If we don't recognize the extension, treat it as an object file.
      // FIXME: The object-file default is carried over from the existing
      // driver, but seems odd.
      let fileType = FileType(rawValue: fileExtension) ?? FileType.object

      return TypedVirtualPath(file: file, type: fileType)
    }
  }

  /// Determine the primary compiler and linker output kinds.
  private static func determinePrimaryOutputs(
    _ parsedOptions: inout ParsedOptions,
    driverKind: DriverKind,
    diagnosticsEngine: DiagnosticsEngine
  ) -> (FileType?, LinkOutputType?) {
    // By default, the driver does not link its output. However, this will be updated below.
    var compilerOutputType: FileType? = (driverKind == .interactive ? nil : .object)
    var linkerOutputType: LinkOutputType? = nil

    if let outputOption = parsedOptions.getLast(in: .modes) {
      switch outputOption.option {
      case .emit_executable:
        if parsedOptions.contains(.static) {
          diagnosticsEngine.emit(.error_static_emit_executable_disallowed)
        }
        linkerOutputType = .executable
        compilerOutputType = .object

      case .emit_library:
        linkerOutputType = parsedOptions.hasArgument(.static) ? .staticLibrary : .dynamicLibrary
        compilerOutputType = .object

      case .emit_object, .c:
        compilerOutputType = .object

      case .emit_assembly:
        compilerOutputType = .assembly

      case .emit_sil:
        compilerOutputType = .sil

      case .emit_silgen:
        compilerOutputType = .raw_sil

      case .emit_sib:
        compilerOutputType = .sib

      case .emit_sibgen:
        compilerOutputType = .raw_sib

      case .emit_ir:
        compilerOutputType = .llvmIR

      case .emit_bc:
        compilerOutputType = .llvmBitcode

      case .dump_ast:
        compilerOutputType = .ast

      case .emit_pch:
        compilerOutputType = .pch

      case .emit_imported_modules:
        compilerOutputType = .importedModules

      case .index_file:
        compilerOutputType = .indexData

      case .update_code:
        compilerOutputType = .remap
        linkerOutputType = nil

      case .parse, .resolve_imports, .typecheck, .dump_parse, .emit_syntax,
           .print_ast, .dump_type_refinement_contexts, .dump_scope_maps,
           .dump_interface_hash, .dump_type_info, .verify_debug_info:
        compilerOutputType = nil

      case .i:
        // FIXME: diagnose this
        break

      case .repl, .deprecated_integrated_repl, .lldb_repl:
        compilerOutputType = nil

      default:
        fatalError("unhandled output mode option \(outputOption)")
      }
    } else if (parsedOptions.hasArgument(.emit_module, .emit_module_path)) {
      compilerOutputType = .swiftModule
    } else if (driverKind != .interactive) {
      linkerOutputType = .executable
    }

    return (compilerOutputType, linkerOutputType)
  }
}

// Multithreading
extension Driver {
  /// Determine the number of threads to use for a multithreaded build,
  /// or zero to indicate a single-threaded build.
  static func determineNumThreads(
    _ parsedOptions: inout ParsedOptions,
    compilerMode: CompilerMode, diagnosticsEngine: DiagnosticsEngine
  ) -> Int {
    guard let numThreadsArg = parsedOptions.getLastArgument(.num_threads) else {
      return 0
    }

    // Make sure we have a non-negative integer value.
    guard let numThreads = Int(numThreadsArg.asSingle), numThreads >= 0 else {
      diagnosticsEngine.emit(Diagnostic.Message.error_invalid_arg_value(arg: .num_threads, value: numThreadsArg.asSingle))
      return 0
    }

    #if false
    // FIXME: Check for batch mode.
    if false {
      diagnosticsEngine.emit(.warning_cannot_multithread_batch_mode)
      return 0
    }
    #endif

    return numThreads
  }
}

// Debug information
extension Driver {
  /// Compute the level of debug information we are supposed to produce.
  private static func computeDebugInfo(_ parsedOptions: inout ParsedOptions, diagnosticsEngine: DiagnosticsEngine) -> (DebugInfoLevel?, DebugInfoFormat) {
    // Determine the debug level.
    let level: DebugInfoLevel?
    if let levelOption = parsedOptions.getLast(in: .g) {
      switch levelOption.option {
      case .g:
        level = .astTypes

      case .gline_tables_only:
        level = .lineTables

      case .gdwarf_types:
        level = .dwarfTypes

      case .gnone:
        level = nil

      default:
        fatalError("Unhandle option in the '-g' group")
      }
    } else {
      level = nil
    }

    // Determine the debug info format.
    let format: DebugInfoFormat
    if let formatArg = parsedOptions.getLastArgument(.debug_info_format) {
      if let parsedFormat = DebugInfoFormat(rawValue: formatArg.asSingle) {
        format = parsedFormat
      } else {
        diagnosticsEngine.emit(.error_invalid_arg_value(arg: .debug_info_format, value: formatArg.asSingle))
        format = .dwarf
      }

      if !parsedOptions.contains(in: .g) {
        diagnosticsEngine.emit(.error_option_missing_required_argument(option: .debug_info_format, requiredArg: .g))
      }
    } else {
      // Default to DWARF.
      format = .dwarf
    }

    if format == .codeView && (level == .lineTables || level == .dwarfTypes) {
      let levelOption = parsedOptions.getLast(in: .g)!.option
      diagnosticsEngine.emit(.error_argument_not_allowed_with(arg: format.rawValue, other: levelOption.spelling))
    }

    return (level, format)
  }
}

// Module computation.
extension Driver {
  /// Compute the base name of the given path without an extension.
  private static func baseNameWithoutExtension(_ path: String) -> String {
    var hasExtension = false
    return baseNameWithoutExtension(path, hasExtension: &hasExtension)
  }

  /// Compute the base name of the given path without an extension.
  private static func baseNameWithoutExtension(_ path: String, hasExtension: inout Bool) -> String {
    if let absolute = try? AbsolutePath(validating: path) {
      hasExtension = absolute.extension != nil
      return absolute.basenameWithoutExt
    }

    if let relative = try? RelativePath(validating: path) {
      hasExtension = relative.extension != nil
      return relative.basenameWithoutExt
    }

    hasExtension = false
    return ""
  }

  /// Whether we are going to be building an executable.
  ///
  /// FIXME: Why "maybe"? Why isn't this all known in advance as captured in
  /// linkerOutputType?
  private static func maybeBuildingExecutable(
    _ parsedOptions: inout ParsedOptions,
    linkerOutputType: LinkOutputType?
  ) -> Bool {
    switch linkerOutputType {
    case .executable:
      return true

    case .dynamicLibrary, .staticLibrary:
      return false

    default:
      break
    }

    if parsedOptions.hasArgument(.parse_as_library, .parse_stdlib) {
      return false
    }

    return parsedOptions.allInputs.count == 1
  }

  /// Determine how the module will be emitted and the name of the module.
  private static func computeModuleInfo(
    _ parsedOptions: inout ParsedOptions,
    compilerOutputType: FileType?,
    compilerMode: CompilerMode,
    linkerOutputType: LinkOutputType?,
    debugInfoLevel: DebugInfoLevel?,
    diagnosticsEngine: DiagnosticsEngine
  ) throws -> (ModuleOutput?, String) {
    // Figure out what kind of module we will output.
    enum ModuleOutputKind {
      case topLevel
      case auxiliary
    }

    var moduleOutputKind: ModuleOutputKind?
    if parsedOptions.hasArgument(.emit_module, .emit_module_path) {
      // The user has requested a module, so generate one and treat it as
      // top-level output.
      moduleOutputKind = .topLevel
    } else if (debugInfoLevel?.requiresModule ?? false) && linkerOutputType != nil {
      // An option has been passed which requires a module, but the user hasn't
      // requested one. Generate a module, but treat it as an intermediate output.
      moduleOutputKind = .auxiliary
    } else if (compilerMode != .singleCompile &&
               parsedOptions.hasArgument(.emit_objc_header, .emit_objc_header_path,
                                         .emit_module_interface, .emit_module_interface_path)) {
      // An option has been passed which requires whole-module knowledge, but we
      // don't have that. Generate a module, but treat it as an intermediate
      // output.
      moduleOutputKind = .auxiliary
    } else {
      // No options require a module, so don't generate one.
      moduleOutputKind = nil
    }

    // The REPL and immediate mode do not support module output
    if moduleOutputKind != nil && (compilerMode == .repl || compilerMode == .immediate) {
      diagnosticsEngine.emit(.error_mode_cannot_emit_module)
      moduleOutputKind = nil
    }

    // Determine the name of the module.
    var moduleName: String
    if let arg = parsedOptions.getLastArgument(.module_name) {
      moduleName = arg.asSingle
    } else if compilerMode == .repl {
      // REPL mode should always use the REPL module.
      moduleName = "REPL"
    } else if let outputArg = parsedOptions.getLastArgument(.o) {
      var hasExtension = false
      var rawModuleName = baseNameWithoutExtension(outputArg.asSingle, hasExtension: &hasExtension)
      if (linkerOutputType == .dynamicLibrary || linkerOutputType == .staticLibrary) &&
        hasExtension && rawModuleName.starts(with: "lib") {
        // Chop off a "lib" prefix if we're building a library.
        rawModuleName = String(rawModuleName.dropFirst(3))
      }

      moduleName = rawModuleName
    } else if parsedOptions.allInputs.count == 1 {
      moduleName = baseNameWithoutExtension(parsedOptions.allInputs.first!)
    } else if compilerOutputType == nil || maybeBuildingExecutable(&parsedOptions, linkerOutputType: linkerOutputType) {
      // FIXME: Current driver notes that this is a "fallback module name"
      moduleName = "main"
    } else {
      // FIXME: Current driver notes that this is a "fallback module name".
      moduleName = ""
    }

    if !moduleName.isSwiftIdentifier {
      diagnosticsEngine.emit(.error_bad_module_name(moduleName: moduleName, explicitModuleName: parsedOptions.contains(.module_name)))
      moduleName = "__bad__"
    } else if moduleName == "Swift" && !parsedOptions.contains(.parse_stdlib) {
      diagnosticsEngine.emit(.error_stdlib_module_name(moduleName: moduleName, explicitModuleName: parsedOptions.contains(.module_name)))
      moduleName = "__bad__"
    }

    // If we're not emiting a module, we're done.
    if moduleOutputKind == nil {
      return (nil, moduleName)
    }

    // Determine the module file to output.
    let moduleOutputPath: VirtualPath

    // FIXME: Look in the output file map. It looks like it is weirdly
    // anchored to the first input?
    if let modulePathArg = parsedOptions.getLastArgument(.emit_module_path) {
      // The module path was specified.
      moduleOutputPath = try VirtualPath(path: modulePathArg.asSingle)
    } else if moduleOutputKind == .topLevel {
      // FIXME: Logic to infer from -o, primary outputs, etc.
      moduleOutputPath = try .init(path: moduleName + "." + FileType.swiftModule.rawValue)
    } else {
      moduleOutputPath = .temporary(moduleName + "." + FileType.swiftModule.rawValue)
    }

    switch moduleOutputKind! {
    case .topLevel:
      return (.topLevel(moduleOutputPath), moduleName)
    case .auxiliary:
      return (.auxiliary(moduleOutputPath), moduleName)
    }
  }
}

// SDK computation.
extension Driver {
  /// Computes the path to the SDK.
  private static func computeSDKPath(
    _ parsedOptions: inout ParsedOptions,
    compilerMode: CompilerMode,
    toolchain: Toolchain,
    diagnosticsEngine: DiagnosticsEngine
  ) -> String? {
    var sdkPath: String?

    if let arg = parsedOptions.getLastArgument(.sdk) {
      sdkPath = arg.asSingle
    } else if let SDKROOT = ProcessEnv.vars["SDKROOT"] {
      sdkPath = SDKROOT
    } else if compilerMode == .immediate || compilerMode == .repl {
      // FIXME: ... is triple macOS ...
      if true {
        // In immediate modes, use the SDK provided by xcrun.
        // This will prefer the SDK alongside the Swift found by "xcrun swift".
        // We don't do this in compilation modes because defaulting to the
        // latest SDK may not be intended.
        sdkPath = try? toolchain.defaultSDKPath()?.pathString
      }
    }

    // Delete trailing /.
    sdkPath = sdkPath.map{ $0.last == "/" ? String($0.dropLast()) : $0 }

    // Validate the SDK if we found one.
    if let sdkPath = sdkPath {
      let path: AbsolutePath

      // FIXME: TSC should provide a better utility for this.
      if let absPath = try? AbsolutePath(validating: sdkPath) {
        path = absPath
      } else if let cwd = localFileSystem.currentWorkingDirectory {
        path = AbsolutePath(sdkPath, relativeTo: cwd)
      } else {
        diagnosticsEngine.emit(.warning_no_such_sdk(sdkPath))
        return sdkPath
      }

      if !localFileSystem.exists(path) {
        diagnosticsEngine.emit(.warning_no_such_sdk(sdkPath))
      }
      // .. else check if SDK is too old (we need target triple to diagnose that).
    }

    return sdkPath
  }
}

// Imported Objective-C header.
extension Driver {
  /// Compute the path of the imported Objective-C header.
  static func computeImportedObjCHeader(_ parsedOptions: inout ParsedOptions, compilerMode: CompilerMode, diagnosticEngine: DiagnosticsEngine) throws -> VirtualPath? {
    guard let objcHeaderPathArg = parsedOptions.getLastArgument(.import_objc_header) else {
      return nil
    }

    // Check for conflicting options.
    if parsedOptions.hasArgument(.import_underlying_module) {
      diagnosticEngine.emit(.error_framework_bridging_header)
    }

    if parsedOptions.hasArgument(.emit_module_interface, .emit_module_interface_path) {
      diagnosticEngine.emit(.error_bridging_header_module_interface)
    }

    let objcHeaderPath = try VirtualPath(path: objcHeaderPathArg.asSingle)
    // FIXME: Precompile bridging header if requested.
    return objcHeaderPath
  }
}

extension Diagnostic.Message {
  static var error_framework_bridging_header: Diagnostic.Message {
    .error("using bridging headers with framework targets is unsupported")
  }

  static var error_bridging_header_module_interface: Diagnostic.Message {
    .error("using bridging headers with module interfaces is unsupported")
  }
}

/// Toolchain computation.
extension Driver {
  static func computeToolchain(
    _ target: Triple,
    diagnosticsEngine: DiagnosticsEngine
  ) throws -> Toolchain {
    switch target.os {
    case .darwin, .macosx, .ios, .tvos, .watchos:
      return DarwinToolchain()
    case .linux:
      return GenericUnixToolchain()
    case .freeBSD, .haiku:
      return GenericUnixToolchain()
    case .win32:
      fatalError("Windows target not supported yet")
    default:
      diagnosticsEngine.emit(.error_unknown_target(target.triple))
    }

    throw Diagnostics.fatalError
  }
}

// Supplementary outputs.
extension Driver {
  /// Determine the output path for a supplementary output.
  static func computeSupplementaryOutputPath(
    _ parsedOptions: inout ParsedOptions,
    type: FileType,
    isOutput: Option?,
    outputPath: Option,
    compilerOutputType: FileType?,
    moduleName: String
  ) throws -> VirtualPath? {
    // FIXME: Do we need to check the output file map?

    // If there is an explicit argument for the output path, use that
    if let outputPathArg = parsedOptions.getLastArgument(outputPath) {
      // Consume the isOutput argument
      if let isOutput = isOutput {
        _ = parsedOptions.hasArgument(isOutput)
      }
      return try VirtualPath(path: outputPathArg.asSingle)
    }

    // If the output option was not provided, don't produce this output at all.
    guard let isOutput = isOutput, parsedOptions.hasArgument(isOutput) else {
      return nil
    }

    // If there is an output argument, derive the name from there.
    if let outputPathArg = parsedOptions.getLastArgument(.o) {
      let path = try VirtualPath(path: outputPathArg.asSingle)

      // If the compiler output is of this type, use the argument directly.
      if type == compilerOutputType {
        return path
      }

      // Otherwise, put this output alongside the requested output.
      let pathString: String
      if let ext = path.extension {
        pathString = String(path.name.dropLast(ext.count + 1))
      } else {
        pathString = path.name
      }

      return try VirtualPath(path: pathString.appendingFileTypeExtension(type))
    }

    return try VirtualPath(path: moduleName.appendingFileTypeExtension(type))
  }
}
