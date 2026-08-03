import SwiftUI

@Observable
@MainActor
final class UntrackedViewModel {
    var formulae: [BrewPackage] = []
    var casks: [BrewPackage] = []
    var isLoading = false
    var error: String? = nil
    var selectedPackageIDs: Set<String> = []
    var filterText = ""

    // MARK: - Computed

    var filteredFormulae: [BrewPackage] {
        filterText.isEmpty ? formulae
            : formulae.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var filteredCasks: [BrewPackage] {
        filterText.isEmpty ? casks
            : casks.filter { $0.name.localizedCaseInsensitiveContains(filterText) }
    }

    var untrackedCount: Int {
        formulae.count + casks.count
    }

    var selectedPackages: [BrewPackage] {
        let ids = selectedPackageIDs
        return (formulae + casks).filter { ids.contains($0.id) }
    }

    /// Single focused package — present only when exactly one row is selected.
    var selectedPackage: BrewPackage? {
        selectedPackageIDs.count == 1 ? selectedPackages.first : nil
    }

    // MARK: - Load

    func load(brewfileEntries: [BrewfileEntry]) async {
        await withLoadingState {
            async let formulaeNames = BrewRunner.shared.listRequestedFormulae()
            async let caskNames     = BrewRunner.shared.listCasks()

            let (fNames, cNames) = try await (formulaeNames, caskNames)
            let tracked = Set(brewfileEntries.map { $0.name })

            let untrackedFormulaeNames = Array(fNames.filter { !tracked.contains($0) })
            let untrackedCaskNames = Array(cNames.filter { !tracked.contains($0) })
            
            async let formulaeInfo = BrewRunner.shared.info(names: untrackedFormulaeNames, kind: .formula)
            async let caskInfo = BrewRunner.shared.info(names: untrackedCaskNames, kind: .cask)
            
            let (fInfo, cInfo) = try await (formulaeInfo, caskInfo)

            self.formulae = fInfo.map { pkg in
                var p = pkg; p.isInBrewfile = false; return p
            }
            self.casks = cInfo.map { pkg in
                var p = pkg; p.isInBrewfile = false; return p
            }
        }
    }

    // MARK: - On-demand detail

    /// Fetch description/version/homepage for a package when it's selected.
    func loadDetail(for package: BrewPackage) async {
        guard package.kind != .tap else { return }
        let packageID = package.id

        async let infoFetch  = BrewRunner.shared.info(names: [package.name], kind: package.kind)
        async let tldrFetch  = BrewRunner.shared.tldr(for: package.name)
        async let manFetch   = BrewRunner.shared.manPage(for: package.name)
        async let usesFetch  = BrewRunner.shared.uses(for: package.name)

        var infos: [BrewPackage]?
        var tldrResult: (summary: String, examples: [TldrExample])
        var manResult: [ManSection]
        var usesResult: [String]

        do {
            infos = try await infoFetch
        } catch {
            infos = nil
        }
        tldrResult = await tldrFetch
        manResult  = await manFetch
        usesResult = await usesFetch

        guard selectedPackage?.id == packageID else { return }

        guard var info = infos?.first else { return }
        info.isInBrewfile        = package.isInBrewfile
        info.tldr                = tldrResult.examples
        info.tldrSummary         = tldrResult.summary
        info.manSections         = manResult
        info.reverseDependencies = usesResult

        updatePackage(name: package.name, kind: package.kind) { _ in info }
    }

    // MARK: - Mutations

    func markInBrewfile(name: String, kind: PackageKind, inBrewfile: Bool) {
        // selectedPackage is computed from the underlying arrays, so updating
        // the array here is enough — no second assignment needed.
        updatePackage(name: name, kind: kind) { $0.with(isInBrewfile: inBrewfile) }
    }

    // MARK: - Private

    private func withLoadingState(_ block: () async throws -> Void) async {
        isLoading = true
        do {
            try await block()
        } catch {
            self.error = error.localizedDescription
        }
        isLoading = false
    }

    private func updatePackage(name: String, kind: PackageKind, transform: (BrewPackage) -> BrewPackage) {
        if kind == .formula, let idx = formulae.firstIndex(where: { $0.name == name }) {
            formulae[idx] = transform(formulae[idx])
        } else if kind == .cask, let idx = casks.firstIndex(where: { $0.name == name }) {
            casks[idx] = transform(casks[idx])
        }
    }
}
