import SwiftUI

@Observable
@MainActor
final class InstalledViewModel {
    var formulae: [BrewPackage] = []
    var casks: [BrewPackage] = []
    var isLoading = false
    var error: String? = nil
    var selectedPackage: BrewPackage? = nil
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
        (formulae + casks).filter { !$0.isInBrewfile }.count
    }

    // MARK: - Load

    func load(brewfileEntries: [BrewfileEntry]) async {
        await withLoadingState {
            async let formulaeNames = BrewRunner.shared.listFormulae()
            async let caskNames     = BrewRunner.shared.listCasks()

            let (fNames, cNames) = try await (formulaeNames, caskNames)
            let tracked = Set(brewfileEntries.map { $0.name })

            self.formulae = fNames.map {
                BrewPackage(name: $0, kind: .formula, isInstalled: true, isInBrewfile: tracked.contains($0))
            }
            self.casks = cNames.map {
                BrewPackage(name: $0, kind: .cask, isInstalled: true, isInBrewfile: tracked.contains($0))
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
        if selectedPackage?.name == package.name {
            selectedPackage = package.kind == .formula
                ? formulae.first { $0.name == package.name }
                : casks.first    { $0.name == package.name }
        }
    }

    // MARK: - Mutations

    func markInBrewfile(name: String, kind: PackageKind, inBrewfile: Bool) {
        updatePackage(name: name, kind: kind) { $0.with(isInBrewfile: inBrewfile) }
        if selectedPackage?.name == name {
            selectedPackage = selectedPackage?.with(isInBrewfile: inBrewfile)
        }
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
