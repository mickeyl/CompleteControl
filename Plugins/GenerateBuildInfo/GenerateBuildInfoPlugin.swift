import PackagePlugin

@main
struct GenerateBuildInfoPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) throws -> [Command] {
        let script = context.package.directory.appending("Scripts/generate-build-info.sh")
        let outputDirectory = context.pluginWorkDirectory.appending("GeneratedBuildInfo")
        return [
            .prebuildCommand(
                displayName: "Generate CompleteControl build revision",
                executable: script,
                arguments: [
                    context.package.directory.string,
                    outputDirectory.string,
                ],
                outputFilesDirectory: outputDirectory
            )
        ]
    }
}
