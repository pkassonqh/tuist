import Basic
import Foundation
import ProjectDescription
import TuistCore
import TuistGenerator

enum GeneratorModelLoaderError: Error, Equatable, FatalError {
    case featureNotYetSupported(String)
    case missingFile(AbsolutePath)
    var type: ErrorType {
        switch self {
        case .featureNotYetSupported:
            return .abort
        case .missingFile:
            return .abort
        }
    }

    var description: String {
        switch self {
        case let .featureNotYetSupported(details):
            return "\(details) is not yet supported"
        case let .missingFile(path):
            return "Couldn't find file at path '\(path.pathString)'"
        }
    }
}

class GeneratorModelLoader: GeneratorModelLoading {
    private let fileHandler: FileHandling
    private let manifestLoader: GraphManifestLoading
    private let manifestTargetGenerator: ManifestTargetGenerating
    private let printer: Printing
    init(fileHandler: FileHandling,
         manifestLoader: GraphManifestLoading,
         manifestTargetGenerator: ManifestTargetGenerating,
         printer: Printing = Printer()) {
        self.fileHandler = fileHandler
        self.manifestLoader = manifestLoader
        self.manifestTargetGenerator = manifestTargetGenerator
        self.printer = printer
    }

    func loadProject(at path: AbsolutePath) throws -> TuistGenerator.Project {
        let manifest = try manifestLoader.loadProject(at: path)
        let project = try TuistGenerator.Project.from(manifest: manifest,
                                                      path: path,
                                                      fileHandler: fileHandler,
                                                      printer: printer)

        let manifestTarget = try manifestTargetGenerator.generateManifestTarget(for: project.name,
                                                                                at: path)

        return project.adding(target: manifestTarget)
    }

    func loadWorkspace(at path: AbsolutePath) throws -> TuistGenerator.Workspace {
        let manifest = try manifestLoader.loadWorkspace(at: path)
        let workspace = try TuistGenerator.Workspace.from(manifest: manifest,
                                                          path: path,
                                                          fileHandler: fileHandler,
                                                          manifestLoader: manifestLoader,
                                                          printer: printer)
        return workspace
    }
}

extension TuistGenerator.Workspace {
    static func from(manifest: ProjectDescription.Workspace,
                     path: AbsolutePath,
                     fileHandler: FileHandling,
                     manifestLoader: GraphManifestLoading,
                     printer: Printing) throws -> TuistGenerator.Workspace {
        func globProjects(_ string: String) -> [AbsolutePath] {
            let projects = fileHandler.glob(path, glob: string)
                .lazy
                .filter(fileHandler.isFolder)
                .filter {
                    manifestLoader.manifests(at: $0).contains(.project)
                }

            if projects.isEmpty {
                printer.print(warning: "No projects found at: \(string)")
            }

            return Array(projects)
        }

        let additionalFiles = manifest.additionalFiles.flatMap {
            TuistGenerator.FileElement.from(manifest: $0,
                                            path: path,
                                            fileHandler: fileHandler,
                                            printer: printer)
        }

        return TuistGenerator.Workspace(name: manifest.name,
                                        projects: manifest.projects.flatMap(globProjects),
                                        additionalFiles: additionalFiles)
    }
}

extension TuistGenerator.FileElement {
    static func from(manifest: ProjectDescription.FileElement,
                     path: AbsolutePath,
                     fileHandler: FileHandling,
                     printer: Printing,
                     includeFiles: @escaping (AbsolutePath) -> Bool = { _ in true }) -> [TuistGenerator.FileElement] {
        func globFiles(_ string: String) -> [AbsolutePath] {
            let files = fileHandler.glob(path, glob: string)
                .filter(includeFiles)

            if files.isEmpty {
                printer.print(warning: "No files found at: \(string)")
            }

            return files
        }

        func folderReferences(_ relativePath: String) -> [AbsolutePath] {
            let folderReferencePath = path.appending(RelativePath(relativePath))

            guard fileHandler.exists(folderReferencePath) else {
                printer.print(warning: "\(relativePath) does not exist")
                return []
            }

            guard fileHandler.isFolder(folderReferencePath) else {
                printer.print(warning: "\(relativePath) is not a directory - folder reference paths need to point to directories")
                return []
            }

            return [folderReferencePath]
        }

        switch manifest {
        case let .glob(pattern: pattern):
            return globFiles(pattern).map(FileElement.file)
        case let .folderReference(path: folderReferencePath):
            return folderReferences(folderReferencePath).map(FileElement.folderReference)
        }
    }
}

extension TuistGenerator.Project {
    static func from(manifest: ProjectDescription.Project,
                     path: AbsolutePath,
                     fileHandler: FileHandling,
                     printer: Printing) throws -> TuistGenerator.Project {
        let name = manifest.name
        let settings = manifest.settings.map { TuistGenerator.Settings.from(manifest: $0, path: path) }
        let targets = try manifest.targets.map {
            try TuistGenerator.Target.from(manifest: $0,
                                           path: path,
                                           fileHandler: fileHandler,
                                           printer: printer)
        }

        let additionalFiles = manifest.additionalFiles.flatMap {
            TuistGenerator.FileElement.from(manifest: $0,
                                            path: path,
                                            fileHandler: fileHandler,
                                            printer: printer)
        }

        return Project(path: path,
                       name: name,
                       settings: settings,
                       filesGroup: .group(name: "Project"),
                       targets: targets,
                       additionalFiles: additionalFiles)
    }

    func adding(target: TuistGenerator.Target) -> TuistGenerator.Project {
        return Project(path: path,
                       name: name,
                       settings: settings,
                       filesGroup: filesGroup,
                       targets: targets + [target],
                       additionalFiles: additionalFiles)
    }
}

extension TuistGenerator.Target {
    static func from(manifest: ProjectDescription.Target,
                     path: AbsolutePath,
                     fileHandler: FileHandling,
                     printer: Printing) throws -> TuistGenerator.Target {
        let name = manifest.name
        let platform = try TuistGenerator.Platform.from(manifest: manifest.platform)
        let product = TuistGenerator.Product.from(manifest: manifest.product)

        let bundleId = manifest.bundleId
        let dependencies = manifest.dependencies.map { TuistGenerator.Dependency.from(manifest: $0) }

        let infoPlist = path.appending(RelativePath(manifest.infoPlist))
        let entitlements = manifest.entitlements.map { path.appending(RelativePath($0)) }

        let settings = manifest.settings.map { TuistGenerator.Settings.from(manifest: $0, path: path) }

        let sources = try TuistGenerator.Target.sources(projectPath: path, sources: manifest.sources?.globs ?? [], fileHandler: fileHandler)

        let resourceFilter = { (path: AbsolutePath) -> Bool in
            TuistGenerator.Target.isResource(path: path, fileHandler: fileHandler)
        }
        let resources = (manifest.resources ?? []).flatMap {
            TuistGenerator.FileElement.from(manifest: $0,
                                            path: path,
                                            fileHandler: fileHandler,
                                            printer: printer,
                                            includeFiles: resourceFilter)
        }

        let headers = manifest.headers.map { TuistGenerator.Headers.from(manifest: $0, path: path, fileHandler: fileHandler) }

        let coreDataModels = try manifest.coreDataModels.map {
            try TuistGenerator.CoreDataModel.from(manifest: $0, path: path, fileHandler: fileHandler)
        }

        let actions = manifest.actions.map { TuistGenerator.TargetAction.from(manifest: $0, path: path) }
        let environment = manifest.environment

        return Target(name: name,
                      platform: platform,
                      product: product,
                      bundleId: bundleId,
                      infoPlist: infoPlist,
                      entitlements: entitlements,
                      settings: settings,
                      sources: sources,
                      resources: resources,
                      headers: headers,
                      coreDataModels: coreDataModels,
                      actions: actions,
                      environment: environment,
                      filesGroup: .group(name: "Project"),
                      dependencies: dependencies)
    }
}

extension TuistGenerator.Settings {
    static func from(manifest: ProjectDescription.Settings, path: AbsolutePath) -> TuistGenerator.Settings {
        let base = manifest.base
        let debug = manifest.debug.flatMap { TuistGenerator.Configuration.from(manifest: $0, path: path) }
        let release = manifest.release.flatMap { TuistGenerator.Configuration.from(manifest: $0, path: path) }
        return Settings(base: base, debug: debug, release: release)
    }
}

extension TuistGenerator.Configuration {
    static func from(manifest: ProjectDescription.Configuration, path: AbsolutePath) -> TuistGenerator.Configuration {
        let settings = manifest.settings
        let xcconfig = manifest.xcconfig.flatMap { path.appending(RelativePath($0)) }
        return Configuration(settings: settings, xcconfig: xcconfig)
    }
}

extension TuistGenerator.TargetAction {
    static func from(manifest: ProjectDescription.TargetAction, path: AbsolutePath) -> TuistGenerator.TargetAction {
        let name = manifest.name
        let tool = manifest.tool
        let order = TuistGenerator.TargetAction.Order.from(manifest: manifest.order)
        let path = manifest.path.map { AbsolutePath($0, relativeTo: path) }
        let arguments = manifest.arguments
        return TargetAction(name: name, order: order, tool: tool, path: path, arguments: arguments)
    }
}

extension TuistGenerator.TargetAction.Order {
    static func from(manifest: ProjectDescription.TargetAction.Order) -> TuistGenerator.TargetAction.Order {
        switch manifest {
        case .pre:
            return .pre
        case .post:
            return .post
        }
    }
}

extension TuistGenerator.CoreDataModel {
    static func from(manifest: ProjectDescription.CoreDataModel,
                     path: AbsolutePath,
                     fileHandler: FileHandling) throws -> TuistGenerator.CoreDataModel {
        let modelPath = path.appending(RelativePath(manifest.path))
        if !fileHandler.exists(modelPath) {
            throw GeneratorModelLoaderError.missingFile(modelPath)
        }
        let versions = fileHandler.glob(modelPath, glob: "*.xcdatamodel")
        let currentVersion = manifest.currentVersion
        return CoreDataModel(path: modelPath, versions: versions, currentVersion: currentVersion)
    }
}

extension TuistGenerator.Headers {
    static func from(manifest: ProjectDescription.Headers, path: AbsolutePath, fileHandler: FileHandling) -> TuistGenerator.Headers {
        let `public` = manifest.public.map { fileHandler.glob(path, glob: $0) } ?? []
        let `private` = manifest.private.map { fileHandler.glob(path, glob: $0) } ?? []
        let project = manifest.project.map { fileHandler.glob(path, glob: $0) } ?? []
        return Headers(public: `public`, private: `private`, project: project)
    }
}

extension TuistGenerator.Dependency {
    static func from(manifest: ProjectDescription.TargetDependency) -> TuistGenerator.Dependency {
        switch manifest {
        case let .target(name):
            return .target(name: name)
        case let .project(target, projectPath):
            return .project(target: target, path: RelativePath(projectPath))
        case let .framework(frameworkPath):
            return .framework(path: RelativePath(frameworkPath))
        case let .library(libraryPath, publicHeaders, swiftModuleMap):
            return .library(path: RelativePath(libraryPath),
                            publicHeaders: RelativePath(publicHeaders),
                            swiftModuleMap: swiftModuleMap.map { RelativePath($0) })
        }
    }
}

extension TuistGenerator.Scheme {
    static func from(manifest: ProjectDescription.Scheme) -> TuistGenerator.Scheme {
        let name = manifest.name
        let shared = manifest.shared
        let buildAction = manifest.buildAction.map { TuistGenerator.BuildAction.from(manifest: $0) }
        let testAction = manifest.testAction.map { TuistGenerator.TestAction.from(manifest: $0) }
        let runAction = manifest.runAction.map { TuistGenerator.RunAction.from(manifest: $0) }

        return Scheme(name: name,
                      shared: shared,
                      buildAction: buildAction,
                      testAction: testAction,
                      runAction: runAction)
    }
}

extension TuistGenerator.BuildAction {
    static func from(manifest: ProjectDescription.BuildAction) -> TuistGenerator.BuildAction {
        return BuildAction(targets: manifest.targets)
    }
}

extension TuistGenerator.TestAction {
    static func from(manifest: ProjectDescription.TestAction) -> TuistGenerator.TestAction {
        let targets = manifest.targets
        let arguments = manifest.arguments.map { TuistGenerator.Arguments.from(manifest: $0) }
        let config = BuildConfiguration.from(manifest: manifest.config)
        let coverage = manifest.coverage
        return TestAction(targets: targets,
                          arguments: arguments,
                          config: config,
                          coverage: coverage)
    }
}

extension TuistGenerator.RunAction {
    static func from(manifest: ProjectDescription.RunAction) -> TuistGenerator.RunAction {
        let config = BuildConfiguration.from(manifest: manifest.config)
        let executable = manifest.executable
        let arguments = manifest.arguments.map { TuistGenerator.Arguments.from(manifest: $0) }

        return RunAction(config: config,
                         executable: executable,
                         arguments: arguments)
    }
}

extension TuistGenerator.Arguments {
    static func from(manifest: ProjectDescription.Arguments) -> TuistGenerator.Arguments {
        return Arguments(environment: manifest.environment,
                         launch: manifest.launch)
    }
}

extension TuistGenerator.BuildConfiguration {
    static func from(manifest: ProjectDescription.BuildConfiguration) -> TuistGenerator.BuildConfiguration {
        switch manifest {
        case .debug:
            return .debug
        case .release:
            return .release
        }
    }
}

extension TuistGenerator.Product {
    static func from(manifest: ProjectDescription.Product) -> TuistGenerator.Product {
        switch manifest {
        case .app:
            return .app
        case .staticLibrary:
            return .staticLibrary
        case .dynamicLibrary:
            return .dynamicLibrary
        case .framework:
            return .framework
        case .staticFramework:
            return .staticFramework
        case .unitTests:
            return .unitTests
        case .uiTests:
            return .uiTests
        }
    }
}

extension TuistGenerator.Platform {
    static func from(manifest: ProjectDescription.Platform) throws -> TuistGenerator.Platform {
        switch manifest {
        case .macOS:
            return .macOS
        case .iOS:
            return .iOS
        case .tvOS:
            return .tvOS
        case .watchOS:
            throw GeneratorModelLoaderError.featureNotYetSupported("watchOS platform")
        }
    }
}
