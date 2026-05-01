import SwiftUI

/// Detail-panel placeholder shown when more than one row is selected.
/// Lists the selected names so the user can confirm what their bulk
/// action will affect.
struct MultiSelectSummary: View {
    let count: Int
    let names: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "square.stack")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text("\(count) packages selected")
                    .font(.title2.bold())
                Spacer()
            }
            .padding(16)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(names.sorted(), id: \.self) { name in
                        Text(name)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 3)
                    }
                }
                .padding(.vertical, 10)
            }
        }
    }
}
