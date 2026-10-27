import XCTest

// Which project a working directory belongs to, mirroring `ecs_detect_project`
// (~/.claude/layers/carefeed/lib/services/ecs/ecs.sh), and the picker model's defaults and cascades.

final class ProjectDetectionTests: XCTestCase {

    private let home = "/Users/me"

    private let repoPaths: [String: [String]] = [
        "admin-portal": ["~/Code/admin-portal"],
        "family-portal": ["~/Code/family-portal", "/work/fp/"],
    ]

    private func detect(_ path: String?, _ paths: [String: [String]]? = nil) -> String? {
        ProjectDetection.detect(path: path, repoPaths: paths ?? repoPaths, home: home)
    }

    func testAPathInsideTheRepoMatches() {
        XCTAssertEqual(detect("/Users/me/Code/admin-portal/app/Models"), "admin-portal")
    }

    func testTheRepoRootItselfMatches() {
        XCTAssertEqual(detect("/Users/me/Code/admin-portal"), "admin-portal")
    }

    func testTildeInARepoPathExpandsToTheGivenHome() {
        XCTAssertEqual(ProjectDetection.detect(path: "/Users/other/Code/admin-portal/x",
                                               repoPaths: repoPaths, home: "/Users/other"), "admin-portal")
        XCTAssertNil(ProjectDetection.detect(path: "/Users/me/Code/admin-portal/x",
                                             repoPaths: repoPaths, home: "/Users/other"))
    }

    func testATrailingSlashOnARepoPathIsIgnored() {
        XCTAssertEqual(detect("/work/fp/src"), "family-portal")
        XCTAssertEqual(detect("/work/fp"), "family-portal")
    }

    func testAWorktreeSiblingMatches() {
        XCTAssertEqual(detect("/Users/me/Code/admin-portal-feature-x"), "admin-portal")
    }

    func testANestedDirectoryOfAWorktreeMatches() {
        XCTAssertEqual(detect("/Users/me/Code/admin-portal-feature-x/app"), "admin-portal")
    }

    func testALookalikeNameWithoutASlashOrDashBoundaryDoesNotMatch() {
        XCTAssertNil(detect("/Users/me/Code/admin-portal2"))
        XCTAssertNil(detect("/Users/me/Code/admin-portalx/app"))
        XCTAssertNil(detect("/Users/me/Code/admin"))
    }

    func testNothingMatchesOutsideEveryRepo() {
        XCTAssertNil(detect("/Users/me/Code/other"))
        XCTAssertNil(detect("/tmp"))
    }

    func testNilAndEmptyPathsMatchNothing() {
        XCTAssertNil(detect(nil))
        XCTAssertNil(detect(""))
    }

    func testAProjectWithNoRepoPathsNeverMatches() {
        XCTAssertNil(detect("/Users/me/Code/admin-portal", ["admin-portal": []]))
        XCTAssertNil(detect("/Users/me/Code/admin-portal", [:]))
    }

    func testTwoProjectsEachMatchTheirOwnRepo() {
        XCTAssertEqual(detect("/Users/me/Code/family-portal/app"), "family-portal")
        XCTAssertEqual(detect("/Users/me/Code/admin-portal/app"), "admin-portal")
        XCTAssertEqual(detect("/Users/me/Code/family-portal-wt"), "family-portal")
    }

    func testWhenTwoProjectsOverlapTheFirstByNameWins() {
        let overlapping = ["zeta": ["~/Code/shared"], "alpha": ["~/Code/shared"]]
        XCTAssertEqual(detect("/Users/me/Code/shared/x", overlapping), "alpha")
    }
}

final class RemoteShellPickerModelTests: XCTestCase {

    private let home = "/Users/me"

    private let targets = RemoteShellTargets(
        configured: true,
        projects: [
            RemoteShellProject(name: "admin-portal", defaultService: "portal", environments: [
                RemoteShellEnvironment(name: "demo", services: ["scheduler", "portal"]),
                RemoteShellEnvironment(name: "production", services: ["scheduler", "portal"]),
            ]),
            RemoteShellProject(name: "family-portal", defaultService: "web", environments: [
                RemoteShellEnvironment(name: "staging", services: ["api", "web"]),
                RemoteShellEnvironment(name: "canada", services: ["worker", "api"]),
            ]),
            RemoteShellProject(name: "empty-project", defaultService: nil, environments: []),
            RemoteShellProject(name: "no-default", defaultService: nil, environments: [
                RemoteShellEnvironment(name: "production", services: ["first", "second"]),
            ]),
        ],
        shellTypes: ["console", "shell", "tinker"],
        repoPaths: ["family-portal": ["~/Code/family-portal"]])

    private func model(path: String? = nil, _ t: RemoteShellTargets? = nil) throws -> RemoteShellPickerModel {
        try XCTUnwrap(RemoteShellPickerModel(targets: t ?? targets, projectPath: path, home: home))
    }

    func testThereIsNoModelWhenThereAreNoProjects() {
        XCTAssertNil(RemoteShellPickerModel(targets: RemoteShellTargets(configured: true), projectPath: nil, home: home))
    }

    func testTheDetectedProjectIsTheInitialProject() throws {
        let m = try model(path: "/Users/me/Code/family-portal/app")
        XCTAssertEqual(m.project, "family-portal")
    }

    func testWithoutADetectedProjectTheFirstProjectIsUsed() throws {
        XCTAssertEqual(try model(path: nil).project, "admin-portal")
        XCTAssertEqual(try model(path: "/tmp/elsewhere").project, "admin-portal")
    }

    func testAnInitialSelectionPrefersProductionTheDefaultServiceAndTheShellType() throws {
        let m = try model()
        XCTAssertEqual(m.project, "admin-portal")
        XCTAssertEqual(m.environment, "production")
        XCTAssertEqual(m.service, "portal")
        XCTAssertEqual(m.shellType, "shell")
        XCTAssertEqual(m.selection, TerminalTarget(project: "admin-portal", environment: "production",
                                                   service: "portal", shellType: "shell"))
    }

    func testWithoutProductionTheFirstEnvironmentAndItsDefaultServiceAreUsed() throws {
        let m = try model(path: "/Users/me/Code/family-portal")
        XCTAssertEqual(m.environment, "staging")
        XCTAssertEqual(m.service, "web")
    }

    func testWithoutADefaultServiceTheFirstServiceIsUsed() throws {
        var m = try model()
        m.selectProject("no-default")
        XCTAssertEqual(m.service, "first")
    }

    func testWithoutAShellTypeNamedShellTheFirstShellTypeIsUsed() throws {
        let t = RemoteShellTargets(configured: true, projects: targets.projects, shellTypes: ["console", "tinker"])
        XCTAssertEqual(try model(t).shellType, "console")
    }

    func testListsReflectWhatTheSelectionOffers() throws {
        let m = try model()
        XCTAssertEqual(m.projects, ["admin-portal", "family-portal", "empty-project", "no-default"])
        XCTAssertEqual(m.environments, ["demo", "production"])
        XCTAssertEqual(m.services, ["scheduler", "portal"])
        XCTAssertEqual(m.shellTypes, ["console", "shell", "tinker"])
    }

    func testSelectingAProjectRedefaultsEnvironmentAndServiceButKeepsTheShellType() throws {
        var m = try model()
        m.selectShellType("tinker")
        m.selectProject("family-portal")
        XCTAssertEqual(m.project, "family-portal")
        XCTAssertEqual(m.environment, "staging")
        XCTAssertEqual(m.service, "web")
        XCTAssertEqual(m.shellType, "tinker")
        XCTAssertEqual(m.environments, ["staging", "canada"])
    }

    func testSelectingAnEnvironmentKeepsTheServiceWhenItIsOffered() throws {
        var m = try model(path: "/Users/me/Code/family-portal")
        m.selectService("api")
        m.selectEnvironment("canada")
        XCTAssertEqual(m.environment, "canada")
        XCTAssertEqual(m.service, "api")
    }

    func testSelectingAnEnvironmentRedefaultsTheServiceWhenItIsNotOffered() throws {
        var m = try model(path: "/Users/me/Code/family-portal")
        m.selectService("web")
        m.selectEnvironment("canada")
        XCTAssertEqual(m.service, "worker", "web is not offered in canada, and neither is the default; the first service is used")
    }

    func testSelectingAServiceAndShellTypeSetsThem() throws {
        var m = try model()
        m.selectService("scheduler")
        m.selectShellType("console")
        XCTAssertEqual(m.selection, TerminalTarget(project: "admin-portal", environment: "production",
                                                   service: "scheduler", shellType: "console"))
    }

    func testSelectingANameThatIsNotOfferedIsIgnored() throws {
        var m = try model()
        let before = m.selection
        m.selectProject("nope")
        m.selectEnvironment("nope")
        m.selectService("nope")
        m.selectShellType("nope")
        XCTAssertEqual(m.selection, before)
    }

    func testAProjectWithNoEnvironmentsYieldsEmptyEnvironmentAndService() throws {
        var m = try model()
        m.selectProject("empty-project")
        XCTAssertEqual(m.project, "empty-project")
        XCTAssertEqual(m.environment, "")
        XCTAssertEqual(m.service, "")
        XCTAssertEqual(m.environments, [])
        XCTAssertEqual(m.services, [])
    }
}
