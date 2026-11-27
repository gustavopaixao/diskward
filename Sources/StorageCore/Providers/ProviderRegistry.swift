import Foundation

public enum ProviderRegistry {
    /// Every provider, in sidebar order.
    public static func all(home: URL = Paths.home, nodeModulesRoots: [URL]? = nil) -> [any CleanupProvider] {
        [
            // System
            UserCachesProvider(home: home),
            LogsProvider(home: home),
            TrashProvider(home: home),
            DownloadsProvider(home: home),
            // Xcode
            DerivedDataProvider(home: home),
            ArchivesProvider(home: home),
            DeviceSupportProvider(home: home),
            SimulatorsProvider(home: home),
            SimulatorRuntimesProvider(),
            // Containers & CI
            DockerProvider(),
            JenkinsProvider(home: home),
            // Package managers
            HomebrewProvider(),
            KnownPathsProvider.javaScript(home: home),
            KnownPathsProvider.python(home: home),
            KnownPathsProvider.jvm(home: home),
            KnownPathsProvider.apple(home: home),
            KnownPathsProvider.go(home: home),
            // Projects
            NodeModulesProvider(home: home, roots: nodeModulesRoots),
        ]
    }
}
