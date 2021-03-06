//===--------------- Planning.swift - Swift Compilation Planning ----------===//
//
// This source file is part of the Swift.org open source project
//
// Copyright (c) 2014 - 2019 Apple Inc. and the Swift project authors
// Licensed under Apache License v2.0 with Runtime Library Exception
//
// See https://swift.org/LICENSE.txt for license information
// See https://swift.org/CONTRIBUTORS.txt for the list of Swift project authors
//
//===----------------------------------------------------------------------===//
/// Planning for builds
extension Driver {
  /// Plan a standard compilation, which produces jobs for compiling separate
  /// primary files.
  private mutating func planStandardCompile() throws -> [Job] {
    var jobs = [Job]()

    // Keep track of the various outputs we care about from the jobs we build.
    var linkerInputs: [TypedVirtualPath] = []
    var moduleInputs: [TypedVirtualPath] = []
    func addJobOutputs(_ jobOutputs: [TypedVirtualPath]) {
      for jobOutput in jobOutputs {
        switch jobOutput.type {
        case .object, .autolink:
          linkerInputs.append(jobOutput)

        case .swiftModule:
          moduleInputs.append(jobOutput)

        default:
          break
        }
      }
    }

    // If we should create emit module job, do so.
    if shouldCreateEmitModuleJob {
      jobs.append(try emitModuleJob())
    }

    let partitions: BatchPartitions?
    if case let .batchCompile(batchInfo) = compilerMode {
      partitions = batchPartitions(batchInfo)
    } else {
      partitions = nil
    }

    for input in inputFiles {
      switch input.type {
      case .swift, .sil, .sib:
        var primaryInputs: [TypedVirtualPath]
        if let partitions = partitions, let partitionIdx = partitions.assignment[input] {
          // We have a partitioning for batch mode. If this input file isn't the first
          // file in the partition, skip it: it's been accounted for already.
          if partitions.partitions[partitionIdx].first! != input {
            continue
          }

          primaryInputs = partitions.partitions[partitionIdx]
        } else {
          primaryInputs = [input]
        }

        var jobOutputs: [TypedVirtualPath] = []
        let job = try compileJob(primaryInputs: primaryInputs, outputType: compilerOutputType, allOutputs: &jobOutputs)
        jobs.append(job)
        addJobOutputs(jobOutputs)

      case .object, .autolink:
        if linkerOutputType != nil {
          linkerInputs.append(input)
        } else {
          diagnosticEngine.emit(.error_unexpected_input_file(input.file))
        }

      case .swiftModule, .swiftDocumentation:
        if moduleOutput != nil && linkerOutputType == nil {
          // When generating a .swiftmodule as a top-level output (as opposed
          // to, for example, linking an image), treat .swiftmodule files as
          // inputs to a MergeModule action.
          moduleInputs.append(input)
        } else if linkerOutputType != nil {
          // Otherwise, if linking, pass .swiftmodule files as inputs to the
          // linker, so that their debug info is available.
          linkerInputs.append(input)
        } else {
          diagnosticEngine.emit(.error_unexpected_input_file(input.file))
        }

      default:
        diagnosticEngine.emit(.error_unexpected_input_file(input.file))
      }
    }

    // Plan the merge-module job, if there are module inputs.
    if moduleOutput != nil && !moduleInputs.isEmpty {
      jobs.append(try mergeModuleJob(inputs: moduleInputs))
    }

    // If we need to autolink-extract, do so.
    let autolinkInputs = linkerInputs.filter { $0.type == .object }
    if let autolinkExtractJob = try autolinkExtractJob(inputs: autolinkInputs) {
      linkerInputs.append(contentsOf: autolinkExtractJob.outputs)
      jobs.append(autolinkExtractJob)
    }

    // If we should link, do so.
    var link: Job?
    if linkerOutputType != nil && !linkerInputs.isEmpty {
      link = try linkJob(inputs: linkerInputs)
      jobs.append(link!)
    }

    // If we should generate a dSYM, do so.
    if let linkJob = link, targetTriple.isDarwin, debugInfoLevel != nil {
      jobs.append(try generateDSYMJob(inputs: linkJob.outputs))
    }

    // FIXME: Lots of follow-up actions for merging modules, etc.

    return jobs
  }

  /// Plan a build by producing a set of jobs to complete the build.
  public mutating func planBuild() throws -> [Job] {
    // Plan the build.
    switch compilerMode {
    case .immediate, .repl, .singleCompile:
      fatalError("Not yet supported")

    case .standardCompile, .batchCompile:
      return try planStandardCompile()
    }
  }
}

extension Diagnostic.Message {
  static func error_unexpected_input_file(_ file: VirtualPath) -> Diagnostic.Message {
    .error("unexpected input file: \(file.name)")
  }
}

// MARK: Batch mode
extension Driver {
  /// Determine the number of partitions we'll use for batch mode.
  private func numberOfBatchPartitions(
    _ info: BatchModeInfo,
    swiftInputFiles: [TypedVirtualPath]
  ) -> Int {
    // If the number of partitions was specified by the user, use it
    if let fixedCount = info.count {
      return fixedCount
    }

    // This is a long comment to justify a simple calculation.
    //
    // Because there is a secondary "outer" build system potentially also
    // scheduling multiple drivers in parallel on separate build targets
    // -- while we, the driver, schedule our own subprocesses -- we might
    // be creating up to $NCPU^2 worth of _memory pressure_.
    //
    // Oversubscribing CPU is typically no problem these days, but
    // oversubscribing memory can lead to paging, which on modern systems
    // is quite bad.
    //
    // In practice, $NCPU^2 processes doesn't _quite_ happen: as core
    // count rises, it usually exceeds the number of large targets
    // without any dependencies between them (which are the only thing we
    // have to worry about): you might have (say) 2 large independent
    // modules * 2 architectures, but that's only an $NTARGET value of 4,
    // which is much less than $NCPU if you're on a 24 or 36-way machine.
    //
    //  So the actual number of concurrent processes is:
    //
    //     NCONCUR := $NCPU * min($NCPU, $NTARGET)
    //
    // Empirically, a frontend uses about 512kb RAM per non-primary file
    // and about 10mb per primary. The number of non-primaries per
    // process is a constant in a given module, but the number of
    // primaries -- the "batch size" -- is inversely proportional to the
    // batch count (default: $NCPU). As a result, the memory pressure
    // we can expect is:
    //
    //  $NCONCUR * (($NONPRIMARYMEM * $NFILE) +
    //              ($PRIMARYMEM * ($NFILE/$NCPU)))
    //
    // If we tabulate this across some plausible values, we see
    // unfortunate memory-pressure results:
    //
    //                          $NFILE
    //                  +---------------------
    //  $NTARGET $NCPU  |  100    500    1000
    //  ----------------+---------------------
    //     2        2   |  2gb   11gb    22gb
    //     4        4   |  4gb   24gb    48gb
    //     4        8   |  5gb   28gb    56gb
    //     4       16   |  7gb   36gb    72gb
    //     4       36   | 11gb   56gb   112gb
    //
    // As it happens, the lower parts of the table are dominated by
    // number of processes rather than the files-per-batch (the batches
    // are already quite small due to the high core count) and the left
    // side of the table is dealing with modules too small to worry
    // about. But the middle and upper-right quadrant is problematic: 4
    // and 8 core machines do not typically have 24-48gb of RAM, it'd be
    // nice not to page on them when building a 4-target project with
    // 500-file modules.
    //
    // Turns we can do that if we just cap the batch size statically at,
    // say, 25 files per batch, we get a better formula:
    //
    //  $NCONCUR * (($NONPRIMARYMEM * $NFILE) +
    //              ($PRIMARYMEM * min(25, ($NFILE/$NCPU))))
    //
    //                          $NFILE
    //                  +---------------------
    //  $NTARGET $NCPU  |  100    500    1000
    //  ----------------+---------------------
    //     2        2   |  1gb    2gb     3gb
    //     4        4   |  4gb    8gb    12gb
    //     4        8   |  5gb   16gb    24gb
    //     4       16   |  7gb   32gb    48gb
    //     4       36   | 11gb   56gb   108gb
    //
    // This means that the "performance win" of batch mode diminishes
    // slightly: the batching factor in the equation drops from
    // ($NFILE/$NCPU) to min(25, $NFILE/$NCPU). In practice this seems to
    // not cost too much: the additional factor in number of subprocesses
    // run is the following:
    //
    //                          $NFILE
    //                  +---------------------
    //  $NTARGET $NCPU  |  100    500    1000
    //  ----------------+---------------------
    //     2        2   |  2x    10x      20x
    //     4        4   |   -     5x      10x
    //     4        8   |   -   2.5x       5x
    //     4       16   |   -  1.25x     2.5x
    //     4       36   |   -      -     1.1x
    //
    // Where - means "no difference" because the batches were already
    // smaller than 25.
    //
    // Even in the worst case here, the 1000-file module on 2-core
    // machine is being built with only 40 subprocesses, rather than the
    // pre-batch-mode 1000. I.e. it's still running 96% fewer
    // subprocesses than before. And significantly: it's doing so while
    // not exceeding the RAM of a typical 2-core laptop.
    let defaultSizeLimit = 25
    let numInputFiles = swiftInputFiles.count
    let sizeLimit = info.sizeLimit ?? defaultSizeLimit

    let numTasks = numParallelJobs ?? 1
    return max(numTasks, numInputFiles / sizeLimit)
  }

  /// Describes the partitions used when batching.
  private struct BatchPartitions {
    /// Assignment of each Swift input file to a particular partition.
    /// The values are indices into `partitions`.
    let assignment: [TypedVirtualPath : Int]

    /// The contents of each partition.
    let partitions: [[TypedVirtualPath]]
  }

  /// Compute the partitions we'll use for batch mode.
  private func batchPartitions(_ info: BatchModeInfo) -> BatchPartitions? {
    let swiftInputFiles = inputFiles.filter { inputFile in
      inputFile.type.isPartOfSwiftCompilation
    }
    let numPartitions = numberOfBatchPartitions(info, swiftInputFiles: swiftInputFiles)

    // If there is only one partition, don't bother.
    if numPartitions == 1 { return nil }

    // Map each input file to a partition index. Ensure that we evenly
    // distribute the remainder.
    let numInputFiles = swiftInputFiles.count
    let remainder = numInputFiles % numPartitions
    let targetSize = numInputFiles / numPartitions
    var partitionIndices: [Int] = []
    for partitionIdx in 0..<numPartitions {
      let fillCount = targetSize + (partitionIdx < remainder ? 1 : 0)
      partitionIndices.append(contentsOf: Array(repeating: partitionIdx, count: fillCount))
    }
    assert(partitionIndices.count == numInputFiles)
    // FIXME: If info.seed is non-null, shuffle.

    // Form the actual partitions.
    var assignment: [TypedVirtualPath : Int] = [:]
    var partitions = Array<[TypedVirtualPath]>(repeating: [], count: numPartitions)
    for (fileIndex, file) in swiftInputFiles.enumerated() {
      let partitionIdx = partitionIndices[fileIndex]
      assignment[file] = partitionIdx
      partitions[partitionIdx].append(file)
    }

    return BatchPartitions(assignment: assignment, partitions: partitions)
  }
}
