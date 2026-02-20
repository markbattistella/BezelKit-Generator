//
// BezelGenerator
// Author: Mark Battistella
// Website: https://markbattistella.com
//

import Foundation

// MARK: - Orchestrator

struct Orchestrator {

    let config: GenerateData

    func run() async throws {
        let logger = Logger(verbose: config.verbose, logDirectory: "./logs")

        let dbManager = DatabaseManager(databasePath: config.database, logger: logger)

        // Step 1: Load database
        logger.info("Loading database: \(config.database)")
        var database = try dbManager.loadDatabase()

        // Step 2: Extract pending devices (filters out already-processed ones)
        let pending = dbManager.extractPending(from: database)
        if pending.isEmpty {
            logger.success("There are no new simulators to process 🎉")
            return
        }
        logger.info("Found \(pending.count) pending device(s) to process")

        // Step 3: Resolve simulators (find existing or install new)
        let runner = SimulatorRunner(
            logger:      logger,
            bundleId:    config.bundleId,
            projectPath: config.project,
            scheme:      config.scheme,
            appOutput:   config.appOutput
        )

        logger.info("Resolving simulators...")
        let (foundSimulators, unfoundSimulators) = try runner.resolveSimulators(from: pending)
        logger.info("Resolved — found: \(foundSimulators.count), unfound: \(unfoundSimulators.count)")

        // Step 4: Build app + run each simulator sequentially
        var results:       [ResolvedSimulator] = []
        var failedAtRuntime: [ResolvedSimulator] = []
        if !foundSimulators.isEmpty {
            (results, failedAtRuntime) = try await runner.generateBezelData(for: foundSimulators)
        } else {
            logger.warn("No simulators available to run; nothing to build.")
        }

        if !failedAtRuntime.isEmpty {
            logger.warn("\(failedAtRuntime.count) simulator(s) failed during run and will be marked problematic")
        }

        // Steps 5-8: Finalizing
        logger.banner("** Finalizing **")

        // Step 5: Merge bezel results into database
        logger.info("Merging results into database...", indent: 2)
        dbManager.merge(results: results, into: &database)

        // Step 6: Clean — reset pending, move unfound + runtime-failed to problematic
        let allUnfound = unfoundSimulators + failedAtRuntime
        dbManager.clean(database: &database, unfound: allUnfound)

        // Step 7: Save sorted cache file + minified resource file
        logger.info("Saving output files...", indent: 2)
        try dbManager.save(
            database:           database,
            cacheOutputPath:    config.database,
            minifiedOutputPath: config.output
        )

        // Step 8: Delete the build output directory
        logger.info("Cleaning up build artifacts...", indent: 2)
        dbManager.deleteOutputDirectory(config.appOutput)

        logger.success("Done.")
    }
}
